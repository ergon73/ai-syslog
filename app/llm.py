"""Абстракция над LLM-провайдером: OpenRouter (приоритет) или Anthropic напрямую."""

import logging

from pydantic import BaseModel

from . import config

log = logging.getLogger("llm")

_client = None


def provider() -> str | None:
    if config.OPENROUTER_API_KEY:
        return "openrouter"
    if config.ANTHROPIC_API_KEY:
        return "anthropic"
    return None


def configured() -> bool:
    return provider() is not None


def _get_client():
    global _client
    if _client is None:
        if provider() == "openrouter":
            from openai import OpenAI

            _client = OpenAI(
                base_url="https://openrouter.ai/api/v1",
                api_key=config.OPENROUTER_API_KEY,
                default_headers={"X-Title": "ai-syslog"},
            )
        else:
            import anthropic

            _client = anthropic.Anthropic()
    return _client


def triage(system: str, user: str, schema: type[BaseModel]) -> dict | None:
    """Структурированный разбор одного сообщения лога."""
    client = _get_client()
    if provider() == "openrouter":
        resp = client.beta.chat.completions.parse(
            model=config.TRIAGE_MODEL,
            max_tokens=1024,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            response_format=schema,
        )
        parsed = resp.choices[0].message.parsed
        return parsed.model_dump() if parsed else None

    resp = client.messages.parse(
        model=config.TRIAGE_MODEL,
        max_tokens=1024,
        system=system,
        messages=[{"role": "user", "content": user}],
        output_format=schema,
    )
    return resp.parsed_output.model_dump() if resp.parsed_output else None


def complete(system: str, user: str, model: str, max_tokens: int = 16000) -> str:
    """Свободный текстовый ответ (дайджест)."""
    client = _get_client()
    if provider() == "openrouter":
        resp = client.chat.completions.create(
            model=model,
            max_tokens=max_tokens,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        )
        return resp.choices[0].message.content or ""

    resp = client.messages.create(
        model=model,
        max_tokens=max_tokens,
        thinking={"type": "adaptive"},
        system=system,
        messages=[{"role": "user", "content": user}],
    )
    return next((b.text for b in resp.content if b.type == "text"), "")
