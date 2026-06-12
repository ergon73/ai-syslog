import asyncio
import logging
import re

from . import config, db

log = logging.getLogger("listener")

# <PRI>остальное — RFC 3164 / то, что шлёт Keenetic
PRI_RE = re.compile(r"^<(\d{1,3})>(.*)$", re.DOTALL)
# "Jun 12 09:30:50 ndhcps: message" / "ndm: Dns::Manager: message"
TAG_RE = re.compile(
    r"^(?:\w{3}\s+\d{1,2}\s[\d:]{8}\s+)?(?:([^\s:]+)\s+)?([\w\-./]+?)(?:\[\d+\])?:\s(.*)$",
    re.DOTALL,
)


def parse_syslog(raw: str, addr_host: str):
    severity = facility = None
    rest = raw
    m = PRI_RE.match(raw)
    if m:
        pri = int(m.group(1))
        severity = pri % 8
        facility = pri // 8
        rest = m.group(2).strip()

    tag, message, host = None, rest, addr_host
    m = TAG_RE.match(rest)
    if m:
        tag = m.group(2)
        message = m.group(3).strip()
        if m.group(1) and not m.group(1)[0].isdigit():
            host = m.group(1)
    return host, severity, facility, tag, message


class SyslogProtocol(asyncio.DatagramProtocol):
    def datagram_received(self, data: bytes, addr):
        raw = data.decode("utf-8", errors="replace").strip()
        if not raw:
            return
        host, severity, facility, tag, message = parse_syslog(raw, addr[0])
        db.insert_log(host, severity, facility, tag, message, raw)


async def run_listener():
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        SyslogProtocol, local_addr=(config.SYSLOG_HOST, config.SYSLOG_PORT)
    )
    log.info("syslog listener on udp://%s:%s", config.SYSLOG_HOST, config.SYSLOG_PORT)
    try:
        await asyncio.Event().wait()
    finally:
        transport.close()
