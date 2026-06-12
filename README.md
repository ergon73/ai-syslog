# ai-syslog

**AI-powered syslog server: every new error in your router's log gets an instant LLM-written explanation — root cause, severity, and what to do about it.**

![Python](https://img.shields.io/badge/python-3.12-blue)
![FastAPI](https://img.shields.io/badge/FastAPI-async-009688)
![License](https://img.shields.io/badge/license-MIT-green)

[Русская версия](README.ru.md)

![Dashboard screenshot](docs/dashboard.png)

*A real WireGuard handshake failure, annotated by the AI in real time: severity, probable cause (ISP-level blocking vs. server downtime), and a concrete recommendation.*

## The idea

Routers and other network gear produce a constant stream of syslog messages. 95% of it is repetitive noise; the remaining 5% is cryptic one-liners like `curl response code: 403, content length: 17` that take real expertise to interpret. ai-syslog receives the raw stream, stores all of it, and asks an LLM to explain **only what's new and only what matters** — so you get expert-level annotations at a cost of well under $1/month.

## How it works

```
router ──UDP 514──▶ listener ──▶ SQLite (raw log, always, everything)
                                    │
                              Drain3 template mining
                                    │  only NEW templates with severity ≤ warning
                                    ▼
                              LLM triage (structured output: severity,
                              cause, recommendation, confidence)
                                    │
                                    ▼
                              FastAPI dashboard: live log with AI
                              annotations inline + daily AI digest
```

### Cost-aware by design

The naive approach — pipe every line through an LLM — burns money on repetition. Instead:

1. **Template mining (Drain3)**: 150 identical `403` errors collapse into one cluster.
2. **Severity gate**: only `warning` and worse get analyzed; DHCP chatter never reaches the LLM.
3. **Annotate once, display everywhere**: an annotation is attached to the *template*, so every matching line in the dashboard shows it for free.
4. **Two-tier models**: a cheap fast model for triage (~$0.0003/call), a stronger one for the daily digest (~$0.005/call).

Real-world cost for a home router: **under $0.50/month**.

### Provider-agnostic

One small abstraction module ([app/llm.py](app/llm.py)) supports:

- **OpenRouter** (default: `google/gemini-2.5-flash-lite` for triage, `openai/gpt-5-mini` for digest)
- **Anthropic API** directly (`claude-haiku-4-5` / `claude-opus-4-8`)

Structured outputs are validated against a Pydantic schema in both cases — the annotation is always well-formed JSON, never free text to parse.

## Quick start

```bash
git clone https://github.com/ergon73/ai-syslog && cd ai-syslog
python -m venv .venv && .venv/Scripts/activate   # Windows; use bin/activate on Linux
pip install -r requirements.txt
cp .env.example .env                              # add your OPENROUTER_API_KEY
python main.py
```

Dashboard: http://127.0.0.1:8514. Without an API key the server still works — it collects logs and mines templates, LLM triage is simply off.

### Point your router at it

Keenetic (web UI): *Management → Diagnostics → System log → send to remote syslog server* → IP of the machine running ai-syslog. Or via CLI:

```
system log server <collector-ip>
system configuration save
```

Any device that speaks RFC 3164 syslog over UDP will work. On Windows, allow inbound UDP 514 from your router:

```powershell
New-NetFirewallRule -DisplayName "ai-syslog UDP 514" -Direction Inbound `
  -Protocol UDP -LocalPort 514 -RemoteAddress <router-ip> -Action Allow
```

## Configuration

All via `.env` (see [.env.example](.env.example)):

| Variable | Default | Purpose |
|---|---|---|
| `OPENROUTER_API_KEY` / `ANTHROPIC_API_KEY` | — | LLM provider (OpenRouter wins if both set) |
| `TRIAGE_MODEL` | `google/gemini-2.5-flash-lite` | per-message analysis |
| `SYNTHESIS_MODEL` | `openai/gpt-5-mini` | daily digest |
| `DEVICE_PROFILE` | generic | description of your network, injected into the system prompt — the more specific, the better the analysis |
| `ANALYZE_SEVERITY_THRESHOLD` | `4` | analyze severity ≤ N (4 = warning and worse) |
| `SYSLOG_PORT` / `WEB_PORT` | `514` / `8514` | ports |

## Roadmap

- [ ] Backfill gaps via the router's REST API on startup (for collectors that aren't always on)
- [ ] Read-only diagnostics: let the analyzer query the router (interface states, routes) while investigating an error
- [ ] Tiered auto-remediation: whitelist of reversible, idempotent fixes with audit log and kill switch
- [ ] Scheduled daily digest + notifications (Telegram)
- [ ] Dockerfile / compose for NAS and single-board deployment

## License

MIT
