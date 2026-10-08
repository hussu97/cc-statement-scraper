"""Sentry initialisation and PII scrubbing for the parser service.

Statements are private financial data. Nothing from the request body (PDF
passwords in ``settings``), the shared secret, or the signed storage URL token
may reach Sentry.
"""

from __future__ import annotations

import logging
import os
import re
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from ccs_parser import PARSER_VERSION

logger = logging.getLogger(__name__)

FILTERED = "[Filtered]"

_SENSITIVE_HEADERS = {"x-parser-secret", "authorization", "cookie", "set-cookie", "proxy-authorization"}
_SENSITIVE_KEY_RE = re.compile(
    r"password|passwd|secret|token|authorization|cookie|api[_-]?key|dsn|^settings$|(?:^|_)cid$",
    re.IGNORECASE,
)
_URL_RE = re.compile(r"https?://[^\s\"'<>]+", re.IGNORECASE)


def strip_query(url: str) -> str:
    """Drop query string and fragment (signed URL tokens live there)."""
    try:
        parts = urlsplit(url)
    except ValueError:
        return FILTERED
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


def _scrub_string(value: str) -> str:
    return _URL_RE.sub(lambda m: strip_query(m.group(0)), value)


def _scrub(value: Any, depth: int = 0) -> Any:
    if depth > 20:
        return FILTERED
    if isinstance(value, dict):
        out: dict[Any, Any] = {}
        for key, item in value.items():
            if isinstance(key, str) and _SENSITIVE_KEY_RE.search(key):
                out[key] = FILTERED
            else:
                out[key] = _scrub(item, depth + 1)
        return out
    if isinstance(value, list | tuple):
        return [_scrub(item, depth + 1) for item in value]
    if isinstance(value, str):
        return _scrub_string(value)
    return value


def _scrub_request(request: dict[str, Any]) -> None:
    request.pop("data", None)  # request body: contains settings/passwords
    request.pop("cookies", None)
    request.pop("query_string", None)
    if isinstance(request.get("url"), str):
        request["url"] = strip_query(request["url"])
    headers = request.get("headers")
    if isinstance(headers, dict):
        request["headers"] = {
            k: (FILTERED if str(k).lower() in _SENSITIVE_HEADERS else _scrub(v)) for k, v in headers.items()
        }
    elif isinstance(headers, list):
        request["headers"] = [
            [k, FILTERED if str(k).lower() in _SENSITIVE_HEADERS else _scrub(v)]
            for k, v in (pair for pair in headers if isinstance(pair, list | tuple) and len(pair) == 2)
        ]


def scrub_event(event: dict[str, Any], hint: dict[str, Any] | None = None) -> dict[str, Any]:
    """``before_send`` / ``before_send_transaction`` hook. Mutates and returns ``event``."""
    request = event.get("request")
    if isinstance(request, dict):
        _scrub_request(request)

    # Local variables in stack frames, breadcrumbs, extra/contexts may carry the
    # request payload, URLs with tokens, or password values.
    for key in ("extra", "contexts", "tags", "breadcrumbs", "exception", "threads", "logentry", "spans", "message"):
        if key in event:
            event[key] = _scrub(event[key])
    return event


def _before_breadcrumb(crumb: dict[str, Any], hint: dict[str, Any] | None = None) -> dict[str, Any]:
    return _scrub(crumb)


# Environments that never report to Sentry, even when a DSN is configured (local
# replays and test runs must not page anyone). Unset means "local".
LOCAL_ENVIRONMENTS = frozenset({"", "local", "development", "test"})


def sentry_environment() -> str:
    return (os.environ.get("SENTRY_ENVIRONMENT") or "").strip() or "local"


def sentry_active(environment: str | None, dsn: str | None) -> bool:
    """True when events should be sent: a DSN is set and the environment is not local."""
    return bool((dsn or "").strip()) and (environment or "").strip().lower() not in LOCAL_ENVIRONMENTS


def init_sentry() -> bool:
    """Initialise Sentry from env. Returns True when enabled."""
    dsn = (os.environ.get("SENTRY_DSN") or "").strip()
    environment = sentry_environment()
    if not sentry_active(environment, dsn):
        if dsn:
            logger.info("Sentry disabled for local environment %r", environment)
        return False
    try:
        import sentry_sdk  # noqa: PLC0415
        from sentry_sdk.integrations.fastapi import FastApiIntegration  # noqa: PLC0415
        from sentry_sdk.integrations.starlette import StarletteIntegration  # noqa: PLC0415
    except ImportError:
        logger.warning("sentry-sdk is not installed; Sentry is disabled")
        return False

    try:
        traces_sample_rate = float(os.environ.get("SENTRY_TRACES_SAMPLE_RATE") or 0.2)
    except ValueError:
        traces_sample_rate = 0.2

    sentry_sdk.init(
        dsn=dsn,
        environment=environment,
        release=(os.environ.get("SENTRY_RELEASE") or "").strip() or None,
        traces_sample_rate=traces_sample_rate,
        send_default_pii=False,
        max_request_body_size="never",
        include_local_variables=False,
        before_send=scrub_event,
        before_send_transaction=scrub_event,
        before_breadcrumb=_before_breadcrumb,
        integrations=[StarletteIntegration(), FastApiIntegration()],
    )
    # credit-card-ledger-backend is shared with the Edge Functions (service=edge).
    sentry_sdk.set_tag("service", "parser")
    sentry_sdk.set_tag("parser_version", PARSER_VERSION)
    logger.info("Sentry initialised | environment=%s traces_sample_rate=%s", environment, traces_sample_rate)
    return True


def set_bank_tag(bank_code: str | None) -> None:
    try:
        import sentry_sdk  # noqa: PLC0415

        sentry_sdk.set_tag("bank_code", bank_code or "unknown")
        sentry_sdk.set_tag("parser_version", PARSER_VERSION)
    except Exception:  # noqa: BLE001
        pass
