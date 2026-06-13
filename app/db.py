import sqlite3
import threading
from datetime import datetime, timezone

from . import config

_local = threading.local()

SCHEMA = """
CREATE TABLE IF NOT EXISTS logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at TEXT NOT NULL,
    host TEXT,
    severity INTEGER,
    facility INTEGER,
    tag TEXT,
    message TEXT NOT NULL,
    raw TEXT NOT NULL,
    template_id INTEGER,
    analyzed INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_logs_analyzed ON logs(analyzed);
CREATE INDEX IF NOT EXISTS idx_logs_template ON logs(template_id);

CREATE TABLE IF NOT EXISTS templates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cluster_id INTEGER UNIQUE NOT NULL,
    template TEXT NOT NULL,
    count INTEGER NOT NULL DEFAULT 0,
    first_seen TEXT NOT NULL,
    last_seen TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS annotations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id INTEGER NOT NULL,
    log_id INTEGER NOT NULL,
    severity_assessment TEXT,
    summary TEXT,
    probable_cause TEXT,
    recommendation TEXT,
    confidence TEXT,
    model TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (template_id) REFERENCES templates(id)
);
CREATE INDEX IF NOT EXISTS idx_annotations_template ON annotations(template_id);
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def get_conn() -> sqlite3.Connection:
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect(config.DB_PATH)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(SCHEMA)
        _local.conn = conn
    return conn


def insert_log(host, severity, facility, tag, message, raw) -> int:
    conn = get_conn()
    cur = conn.execute(
        "INSERT INTO logs (received_at, host, severity, facility, tag, message, raw)"
        " VALUES (?, ?, ?, ?, ?, ?, ?)",
        (now_iso(), host, severity, facility, tag, message, raw),
    )
    conn.commit()
    return cur.lastrowid


def fetch_unanalyzed(limit=200):
    conn = get_conn()
    return conn.execute(
        "SELECT * FROM logs WHERE analyzed = 0 ORDER BY id LIMIT ?", (limit,)
    ).fetchall()


def mark_analyzed(log_id: int, template_id: int):
    conn = get_conn()
    conn.execute(
        "UPDATE logs SET analyzed = 1, template_id = ? WHERE id = ?",
        (template_id, log_id),
    )
    conn.commit()


def upsert_template(cluster_id: int, template: str) -> int:
    conn = get_conn()
    ts = now_iso()
    row = conn.execute(
        "SELECT id FROM templates WHERE cluster_id = ?", (cluster_id,)
    ).fetchone()
    if row:
        conn.execute(
            "UPDATE templates SET template = ?, count = count + 1, last_seen = ?"
            " WHERE id = ?",
            (template, ts, row["id"]),
        )
        conn.commit()
        return row["id"]
    cur = conn.execute(
        "INSERT INTO templates (cluster_id, template, count, first_seen, last_seen)"
        " VALUES (?, ?, 1, ?, ?)",
        (cluster_id, template, ts, ts),
    )
    conn.commit()
    return cur.lastrowid


def template_has_annotation(template_id: int) -> bool:
    conn = get_conn()
    row = conn.execute(
        "SELECT 1 FROM annotations WHERE template_id = ? LIMIT 1", (template_id,)
    ).fetchone()
    return row is not None


def insert_annotation(template_id, log_id, result: dict, model: str):
    conn = get_conn()
    conn.execute(
        "INSERT INTO annotations (template_id, log_id, severity_assessment, summary,"
        " probable_cause, recommendation, confidence, model, created_at)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            template_id,
            log_id,
            result.get("severity_assessment"),
            result.get("summary"),
            result.get("probable_cause"),
            result.get("recommendation"),
            result.get("confidence"),
            model,
            now_iso(),
        ),
    )
    conn.commit()


def fetch_context(log_id: int, lines: int = 15):
    conn = get_conn()
    rows = conn.execute(
        "SELECT received_at, tag, message FROM logs WHERE id < ? ORDER BY id DESC LIMIT ?",
        (log_id, lines),
    ).fetchall()
    return list(reversed(rows))


def fetch_recent_logs(limit=300):
    conn = get_conn()
    return conn.execute(
        """
        SELECT l.*, a.severity_assessment, a.summary, a.probable_cause,
               a.recommendation, a.confidence
        FROM logs l
        LEFT JOIN annotations a ON a.template_id = l.template_id
        ORDER BY l.id DESC LIMIT ?
        """,
        (limit,),
    ).fetchall()


def fetch_dhcp_lines():
    """Строки с привязками MAC↔hostname и IP↔MAC — для карты устройств."""
    conn = get_conn()
    return conn.execute(
        "SELECT message FROM logs "
        "WHERE message LIKE '%hostname \"%' OR message LIKE '%ACK of %'"
    ).fetchall()


def fetch_errors_since(hours: int = 24):
    conn = get_conn()
    return conn.execute(
        """
        SELECT l.received_at, l.severity, l.tag, l.message
        FROM logs l
        WHERE l.severity <= 4
          AND datetime(l.received_at) >= datetime('now', ?)
        ORDER BY l.id
        """,
        (f"-{hours} hours",),
    ).fetchall()
