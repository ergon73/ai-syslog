"""Определение вендора по MAC-адресу: локальная база Wireshark manuf (IEEE OUI).

Файл скачивается в data/ и обновляется автоматически раз в 30 дней.
LLM для этого не нужен — чистый офлайн-справочник.
"""

import logging
import re
import time
import urllib.request

from . import config

log = logging.getLogger("oui")

MANUF_URL = "https://www.wireshark.org/download/automated/data/manuf"
MANUF_PATH = config.DATA_DIR / "manuf.txt"
MAX_AGE_SECONDS = 30 * 86400

MAC_RE = re.compile(r"\b[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}\b")

_table: dict[str, str] | None = None


def _ensure_file():
    try:
        fresh = (
            MANUF_PATH.exists()
            and time.time() - MANUF_PATH.stat().st_mtime < MAX_AGE_SECONDS
        )
        if not fresh:
            log.info("downloading OUI database from %s", MANUF_URL)
            urllib.request.urlretrieve(MANUF_URL, MANUF_PATH)
    except Exception:
        log.exception("OUI database download failed; using stale/empty data")


def _load() -> dict[str, str]:
    global _table
    if _table is not None:
        return _table
    _ensure_file()
    table: dict[str, str] = {}
    if MANUF_PATH.exists():
        with open(MANUF_PATH, encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.strip() or line.startswith("#"):
                    continue
                parts = [p.strip() for p in line.rstrip("\n").split("\t")]
                prefix = parts[0].lower()
                if "/" in prefix or len(prefix) != 8:
                    continue  # пропускаем маскированные диапазоны, хватает OUI/24
                name = parts[2] if len(parts) > 2 and parts[2] else parts[1]
                table[prefix] = name
    log.info("OUI database loaded: %d prefixes", len(table))
    _table = table
    return table


def vendor(mac: str) -> str:
    mac = mac.lower()
    first_octet = int(mac[0:2], 16)
    if first_octet & 0x02:
        return "рандомизированный MAC (приватный адрес, вендор скрыт)"
    return _load().get(mac[0:8], "неизвестный вендор")


def enrich(text: str) -> list[dict]:
    """Все MAC в тексте с вендорами: [{mac, vendor}, ...] без дублей."""
    seen, result = set(), []
    for m in MAC_RE.findall(text):
        key = m.lower()
        if key not in seen:
            seen.add(key)
            result.append({"mac": m, "vendor": vendor(m)})
    return result
