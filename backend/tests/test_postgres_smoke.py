from __future__ import annotations

import os

import pytest
from sqlalchemy import text

from ccs_platform.core.settings import get_settings
from ccs_platform.db import db_session, init_db


pytestmark = pytest.mark.skipif(
    not os.getenv("CCS_PLATFORM_DATABASE_URL", "").startswith(("postgres://", "postgresql://", "postgresql+psycopg://")),
    reason="Postgres smoke test only runs when CCS_PLATFORM_DATABASE_URL points to PostgreSQL.",
)


def test_postgres_backend_smoke() -> None:
    settings = get_settings()
    assert settings.resolved_database_url().startswith("postgresql+psycopg://")

    init_db()
    with db_session() as db:
        result = db.execute(text("SELECT 1")).scalar_one()
        assert int(result) == 1
