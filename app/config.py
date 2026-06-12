import os
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

DATA_DIR = Path(os.getenv("DATA_DIR", BASE_DIR / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

DB_PATH = DATA_DIR / "syslog.db"
DRAIN_STATE_PATH = DATA_DIR / "drain3_state.bin"

IGNORE_PATTERNS_FILE = BASE_DIR / "ignore_patterns.txt"

SYSLOG_HOST = os.getenv("SYSLOG_HOST", "0.0.0.0")
SYSLOG_PORT = int(os.getenv("SYSLOG_PORT", "514"))

WEB_HOST = os.getenv("WEB_HOST", "127.0.0.1")
WEB_PORT = int(os.getenv("WEB_PORT", "8514"))

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")

# Триаж — дёшево и часто; синтез — дороже и редко.
# Дефолты зависят от провайдера: OpenRouter (если есть ключ) или Anthropic.
if OPENROUTER_API_KEY:
    _default_triage = "google/gemini-2.5-flash-lite"
    _default_synthesis = "openai/gpt-5-mini"
else:
    _default_triage = "claude-haiku-4-5"
    _default_synthesis = "claude-opus-4-8"

TRIAGE_MODEL = os.getenv("TRIAGE_MODEL", _default_triage)
SYNTHESIS_MODEL = os.getenv("SYNTHESIS_MODEL", _default_synthesis)

# Анализируем сообщения с severity <= порога (0=emerg .. 7=debug).
# 4 = warning и хуже.
ANALYZE_SEVERITY_THRESHOLD = int(os.getenv("ANALYZE_SEVERITY_THRESHOLD", "4"))

# Профиль устройства подставляется в системный промпт анализатора.
# Опишите свою сеть в .env (DEVICE_PROFILE) — чем конкретнее, тем точнее разборы.
DEVICE_PROFILE = os.getenv(
    "DEVICE_PROFILE",
    "Домашний роутер (модель не указана). Опишите модель, тип WAN-подключения, "
    "VPN-туннели и особенности сети в переменной DEVICE_PROFILE.",
)
