from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def init_sentry(settings: object) -> None:
    dsn = (getattr(settings, "sentry_dsn", None) or "").strip()
    if not dsn:
        return

    try:
        import sentry_sdk
        from sentry_sdk.integrations.fastapi import FastApiIntegration
        from sentry_sdk.integrations.sqlalchemy import SqlalchemyIntegration
    except ImportError:
        logger.warning("sentry-sdk is not installed; Sentry is disabled")
        return

    environment = (getattr(settings, "environment", "development") or "development").strip()
    traces_sample_rate = float(getattr(settings, "sentry_traces_sample_rate", 0.1))

    sentry_sdk.init(
        dsn=dsn,
        environment=environment,
        traces_sample_rate=traces_sample_rate,
        integrations=[
            FastApiIntegration(),
            SqlalchemyIntegration(),
        ],
        send_default_pii=False,
    )
    logger.info("Sentry initialised | environment=%s traces_sample_rate=%s", environment, traces_sample_rate)
