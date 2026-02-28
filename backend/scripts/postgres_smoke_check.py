#!/usr/bin/env python3
from __future__ import annotations

from sqlalchemy import func
from sqlalchemy import text

from ccs_platform.application.bootstrap.seed import seed_defaults
from ccs_platform.core.settings import get_settings
from ccs_platform.db import db_session, init_db, models


def main() -> int:
    settings = get_settings()
    resolved_url = settings.resolved_database_url()
    if not resolved_url.startswith("postgresql+psycopg://"):
        raise RuntimeError(
            "CCS_PLATFORM_DATABASE_URL must resolve to a psycopg Postgres URL "
            "(postgresql+psycopg://...) for Postgres smoke validation."
        )

    init_db()
    with db_session() as db:
        db.execute(text("SELECT 1"))
        seed_defaults(db)
        profile_count = int(db.query(func.count(models.Profile.id)).scalar())

    print(f"Postgres smoke check passed | profiles={profile_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
