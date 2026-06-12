import asyncio
import logging

import uvicorn

from app import config, llm
from app.analyzer import run_analyzer
from app.listener import run_listener
from app.web import app as web_app

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s"
)


async def main():
    server = uvicorn.Server(
        uvicorn.Config(web_app, host=config.WEB_HOST, port=config.WEB_PORT, log_level="warning")
    )
    print(f"Дашборд:  http://{config.WEB_HOST}:{config.WEB_PORT}")
    print(f"Syslog:   udp://{config.SYSLOG_HOST}:{config.SYSLOG_PORT}")
    if llm.configured():
        print(f"LLM:      {llm.provider()} (триаж: {config.TRIAGE_MODEL}, синтез: {config.SYNTHESIS_MODEL})")
    else:
        print("ВНИМАНИЕ: ключ не задан (OPENROUTER_API_KEY или ANTHROPIC_API_KEY) — LLM-разбор выключен.")
    await asyncio.gather(run_listener(), run_analyzer(), server.serve())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
