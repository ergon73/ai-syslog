import asyncio
import logging
import re
from typing import Literal

from pydantic import BaseModel

from . import config, db, llm, mining, oui

log = logging.getLogger("analyzer")

SEVERITY_NAMES = {
    0: "emerg", 1: "alert", 2: "crit", 3: "error",
    4: "warning", 5: "notice", 6: "info", 7: "debug",
}


class TriageResult(BaseModel):
    severity_assessment: Literal["critical", "error", "warning", "info", "noise"]
    summary: str
    probable_cause: str
    recommendation: str
    confidence: Literal["low", "medium", "high"]


SYSTEM_PROMPT = f"""Ты — эксперт по сетевому оборудованию и анализу syslog.
Устройство: {config.DEVICE_PROFILE}

Тебе дают одно сообщение журнала (с контекстом предшествующих строк) с этого
устройства. Разбери его для администратора домашней сети:
- severity_assessment: реальная серьёзность с точки зрения работы сети
  (noise = можно игнорировать, info = полезно знать, warning/error/critical = требует внимания);
- summary: одно предложение по-русски, что произошло;
- probable_cause: наиболее вероятная причина (учитывай контекст: блокировки DPI,
  нестабильный загородный интернет, особенности Keenetic);
- recommendation: что сделать администратору; если делать ничего не нужно, так и скажи;
- confidence: насколько ты уверен в разборе.

Важно: твой разбор будет показан под ВСЕМИ сообщениями этого же типа (с другими
MAC/IP/кодами), поэтому пиши обобщённо — описывай суть события и класс причин,
не привязывайся к конкретному MAC-адресу или коду из примера, если суть не в них.

Будь конкретным и кратким. Не выдумывай факты, которых нет в логе."""


def _load_ignore_patterns() -> list[re.Pattern]:
    patterns = []
    try:
        with open(config.IGNORE_PATTERNS_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    patterns.append(re.compile(line, re.IGNORECASE))
    except FileNotFoundError:
        pass
    return patterns


IGNORE_PATTERNS = _load_ignore_patterns()


def is_ignored(message: str) -> bool:
    return any(p.search(message) for p in IGNORE_PATTERNS)

def triage_with_llm(row, context_rows) -> dict | None:
    context = "\n".join(
        f"{r['received_at']} {r['tag'] or '-'}: {r['message']}" for r in context_rows
    )
    sev = SEVERITY_NAMES.get(row["severity"], "?")
    macs = oui.enrich(row["message"])
    mac_info = ""
    if macs:
        mac_info = "\n\nВендоры MAC-адресов из сообщения:\n" + "\n".join(
            f"- {m['mac']}: {m['vendor']}" for m in macs
        )
    user_msg = (
        f"Контекст (предыдущие строки журнала):\n{context or '(пусто)'}\n\n"
        f"Анализируемое сообщение [{sev}] {row['tag'] or '-'}:\n{row['message']}"
        f"{mac_info}"
    )
    return llm.triage(SYSTEM_PROMPT, user_msg, TriageResult)


def process_batch() -> int:
    """Один проход: размечает необработанные строки. Возвращает число строк."""
    rows = db.fetch_unanalyzed()
    for row in rows:
        cluster_id, template = mining.add_message(row["message"])
        template_id = db.upsert_template(cluster_id, template)

        should_analyze = (
            row["severity"] is not None
            and row["severity"] <= config.ANALYZE_SEVERITY_THRESHOLD
            and not db.template_has_annotation(template_id)
            and not is_ignored(row["message"])
        )
        if should_analyze:
            if llm.configured():
                try:
                    context = db.fetch_context(row["id"])
                    result = triage_with_llm(row, context)
                    if result:
                        db.insert_annotation(
                            template_id, row["id"], result, config.TRIAGE_MODEL
                        )
                        log.info(
                            "annotated template %s: %s",
                            template_id,
                            result["summary"],
                        )
                except Exception:
                    log.exception("LLM triage failed for log %s", row["id"])
            else:
                log.warning(
                    "API-ключ не задан (OPENROUTER_API_KEY/ANTHROPIC_API_KEY) — "
                    "пропускаю LLM-разбор (log %s)",
                    row["id"],
                )
        db.mark_analyzed(row["id"], template_id)
    return len(rows)


async def run_analyzer(poll_interval: float = 3.0):
    log.info(
        "analyzer started (triage=%s, threshold=%s)",
        config.TRIAGE_MODEL,
        config.ANALYZE_SEVERITY_THRESHOLD,
    )
    while True:
        processed = await asyncio.to_thread(process_batch)
        if processed == 0:
            await asyncio.sleep(poll_interval)


def build_digest(hours: int = 24) -> str:
    """Суточный синтез: связная картина проблем за период (модель уровня Opus)."""
    rows = db.fetch_errors_since(hours)
    if not rows:
        return f"За последние {hours} ч. сообщений уровня warning и хуже не было."
    lines = "\n".join(
        f"{r['received_at']} [{SEVERITY_NAMES.get(r['severity'], '?')}] "
        f"{r['tag'] or '-'}: {r['message']}"
        for r in rows[:2000]
    )
    user_msg = (
        f"Вот все сообщения уровня warning и хуже за последние {hours} ч. "
        f"({len(rows)} строк). Составь связный дайджест по-русски: "
        "сгруппируй по проблемам, оцени динамику, выдели что требует "
        "действий, а что — фоновый шум. Формат: markdown.\n\n" + lines
    )
    return llm.complete(SYSTEM_PROMPT, user_msg, config.SYNTHESIS_MODEL)
