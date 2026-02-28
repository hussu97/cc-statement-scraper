from __future__ import annotations

from fastapi import Request


def request_idempotency_key(request: Request) -> str | None:
    for header in ("Idempotency-Key", "X-Idempotency-Key"):
        value = request.headers.get(header)
        if value and value.strip():
            return value.strip()
    return None
