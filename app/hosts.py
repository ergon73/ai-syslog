"""Карта устройств: MAC/IP → понятное имя.

Имена выучиваются АВТОМАТИЧЕСКИ из DHCP-строк в логах (Keenetic пишет
hostname в каждом DHCPREQUEST/DISCOVER). Дополнительно можно задать
переопределения в hosts.txt — для того, что DHCP знать не может
(например, роль устройства). hosts.txt в .gitignore; пример — hosts.example.txt.

Никаких личных данных в репозитории: карта строится в рантайме из ваших логов.
"""

import ipaddress
import logging
import re
import time

from . import config, db, oui

log = logging.getLogger("hosts")

MAC_RE = re.compile(r"\b[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}\b")
IP_RE = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")
_DHCP_HOST_RE = re.compile(r'from ([0-9a-fA-F:]{17}) hostname "([^"]+)"')
_ACK_RE = re.compile(r"ACK of (\d{1,3}(?:\.\d{1,3}){3}) to ([0-9a-fA-F:]{17})")

_CACHE_TTL = 60
_cache = {"ts": 0.0, "mac2name": {}, "ip2mac": {}}
_manual: dict[str, str] | None = None


def _load_manual() -> dict[str, str]:
    global _manual
    if _manual is not None:
        return _manual
    _manual = {}
    try:
        with open(config.HOSTS_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                token, name = line.split("=", 1)
                _manual[token.strip().lower()] = name.strip()
    except FileNotFoundError:
        pass
    return _manual


def _maps() -> dict:
    now = time.time()
    if now - _cache["ts"] < _CACHE_TTL and _cache["mac2name"]:
        return _cache
    mac2name, ip2mac = {}, {}
    try:
        for row in db.fetch_dhcp_lines():
            msg = row["message"]
            m = _DHCP_HOST_RE.search(msg)
            if m:
                mac2name[m.group(1).lower()] = m.group(2)
            a = _ACK_RE.search(msg)
            if a:
                ip2mac[a.group(1)] = a.group(2).lower()
    except Exception:
        log.exception("building host map failed")
    _cache.update(ts=now, mac2name=mac2name, ip2mac=ip2mac)
    return _cache


def _is_private(ip: str) -> bool:
    try:
        return ipaddress.ip_address(ip).is_private
    except ValueError:
        return False


def name_for_mac(mac: str) -> str | None:
    mac = mac.lower()
    return _load_manual().get(mac) or _maps()["mac2name"].get(mac)


def enrich(text: str) -> list[dict]:
    """Известные устройства в тексте: [{token, kind, name, vendor}], без дублей."""
    maps = _maps()
    manual = _load_manual()
    seen, out = set(), []

    for mac in MAC_RE.findall(text):
        key = mac.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(
            {
                "token": mac,
                "kind": "mac",
                "name": manual.get(key) or maps["mac2name"].get(key),
                "vendor": oui.vendor(mac),
            }
        )

    for ip in IP_RE.findall(text):
        if ip in seen or not _is_private(ip):
            continue
        seen.add(ip)
        mac = maps["ip2mac"].get(ip)
        name = manual.get(ip) or (maps["mac2name"].get(mac) if mac else None)
        if name:  # показываем IP, только если знаем, что это за устройство
            out.append(
                {
                    "token": ip,
                    "kind": "ip",
                    "name": name,
                    "vendor": oui.vendor(mac) if mac else None,
                }
            )
    return out


def format_line(e: dict) -> str:
    parts = [p for p in (e.get("name"), e.get("vendor")) if p]
    return f"{e['token']} — {', '.join(parts)}" if parts else e["token"]
