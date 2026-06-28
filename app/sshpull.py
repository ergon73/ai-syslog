"""Забор логов роутера по SSH из файла syslog-ng (durable, без потерь).

Роутер пишет свой syslog в файл на флешке (через syslog-ng). Этот модуль
по SSH дочитывает ТОЛЬКО новые байты с последней позиции (offset хранится
в БД), парсит и кладёт строки в logs — дальше их подхватывает analyzer.
Ноутбук может быть выключен сутками: файл на флешке копится, при возврате
дочитываем с того места, где остановились. Потерь нет.

Формат строк в файле (template syslog-ng):
    UNIXTIME \t LEVEL \t HOST \t PROGRAM \t MSG
"""

import asyncio
import logging
import subprocess
from datetime import datetime, timezone

from . import config, db

log = logging.getLogger("sshpull")

SEV = {
    "emerg": 0, "panic": 0, "alert": 1, "crit": 2, "err": 3, "error": 3,
    "warning": 4, "warn": 4, "notice": 5, "info": 6, "debug": 7,
}

MAX_CHUNK = 2 * 1024 * 1024  # читаем не более 2 МБ за один опрос
OFFSET_KEY = "ssh_offset"


def _ssh(remote_cmd: str) -> bytes:
    r = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         config.SSH_ALIAS, remote_cmd],
        capture_output=True, timeout=40,
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode("utf-8", "replace").strip() or "ssh failed")
    return r.stdout


def _remote_size() -> int:
    # busybox stat не знает -c, поэтому wc -c (универсально)
    out = _ssh(f"wc -c < {config.REMOTE_LOG} 2>/dev/null || echo 0")
    try:
        return int(out.decode().strip() or "0")
    except ValueError:
        return 0


def _ingest(line: str):
    parts = line.split("\t", 4)
    if len(parts) < 5:
        db.insert_log_at(db.now_iso(), None, None, None, None, line, line)
        return
    ut, level, host, program, msg = parts
    sev = SEV.get(level.strip().lower())
    try:
        received = (
            datetime.fromtimestamp(int(ut), timezone.utc)
            .astimezone().isoformat(timespec="seconds")
        )
    except (ValueError, OverflowError):
        received = db.now_iso()
    db.insert_log_at(received, host or None, sev, None, program or None, msg, line)


def pull_once() -> int:
    offset = db.get_state_int(OFFSET_KEY, 0)
    size = _remote_size()
    if size == 0:
        return 0
    if size < offset:  # файл усечён/проротирован — начинаем сначала
        log.info("remote log shrank (%d < %d), сбрасываю offset", size, offset)
        offset = 0
    if size <= offset:
        return 0
    data = _ssh(f"tail -c +{offset + 1} {config.REMOTE_LOG} | head -c {MAX_CHUNK}")
    if not data:
        return 0
    last_nl = data.rfind(b"\n")
    if last_nl < 0:  # ни одной завершённой строки — ждём следующего опроса
        return 0
    complete = data[: last_nl + 1]
    n = 0
    for raw in complete.split(b"\n"):
        if not raw.strip():
            continue
        _ingest(raw.decode("utf-8", "replace"))
        n += 1
    db.set_state_int(OFFSET_KEY, offset + len(complete))
    return n


async def run_sshpull():
    log.info(
        "ssh-pull старт: %s:%s каждые %ss",
        config.SSH_ALIAS, config.REMOTE_LOG, config.SSH_POLL_INTERVAL,
    )
    while True:
        try:
            n = await asyncio.to_thread(pull_once)
            if n:
                log.info("дочитано строк с роутера: %d", n)
        except Exception as e:
            log.warning("ssh-pull сбой: %s", e)
        await asyncio.sleep(config.SSH_POLL_INTERVAL)
