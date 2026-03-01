from __future__ import annotations

from contextlib import contextmanager
from functools import lru_cache
import logging
from pathlib import Path
from typing import Generator

from alembic.config import Config as AlembicConfig
from alembic import command as alembic_command
from sqlalchemy import create_engine
from sqlalchemy import inspect
from sqlalchemy.orm import Session, sessionmaker

from ccs_platform.core.settings import get_settings
from ccs_platform.db.base import Base

# alembic.ini sits two levels above this file: backend/alembic.ini (dev)
# or /app/alembic.ini (Docker container).
_ALEMBIC_INI = Path(__file__).resolve().parents[2] / "alembic.ini"

logger = logging.getLogger(__name__)


def _engine_kwargs(database_url: str) -> dict:
    kwargs: dict = {"future": True, "pool_pre_ping": True}
    if database_url.startswith("sqlite"):
        kwargs["connect_args"] = {"check_same_thread": False}
    else:
        # On managed Postgres (e.g. Render free tier) idle connections are
        # dropped server-side after ~5 min.  pool_pre_ping catches stale
        # connections but adds a round-trip; pool_recycle proactively retires
        # them before they go stale.  Keep the pool small to stay within the
        # free tier's 25-connection limit.
        kwargs["pool_size"] = 2
        kwargs["max_overflow"] = 2
        kwargs["pool_recycle"] = 300  # seconds — retire connections after 5 min
    return kwargs


def _ensure_sqlite_parent_dir(database_url: str) -> None:
    if not database_url.startswith("sqlite"):
        return

    raw_path: str | None = None
    for prefix in ("sqlite+pysqlite:///", "sqlite:///"):
        if database_url.startswith(prefix):
            raw_path = database_url[len(prefix):]
            break

    if not raw_path:
        return

    # SQLite in-memory and URI-mode targets do not map to local filesystem paths.
    if raw_path == ":memory:" or raw_path.startswith("file:"):
        return

    raw_path = raw_path.split("?", 1)[0]
    db_path = Path(raw_path).expanduser()
    db_path.parent.mkdir(parents=True, exist_ok=True)


@lru_cache(maxsize=1)
def get_engine():
    settings = get_settings()
    url = settings.resolved_database_url()
    _ensure_sqlite_parent_dir(url)
    _engine = create_engine(url, **_engine_kwargs(url))
    if settings.database_url != url:
        logger.info("Normalized database URL driver to psycopg for Postgres backend.")
    return _engine


@lru_cache(maxsize=1)
def get_session_local():
    return sessionmaker(bind=get_engine(), autoflush=False, autocommit=False, future=True)


def get_db() -> Generator[Session, None, None]:
    db = get_session_local()()
    try:
        yield db
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


@contextmanager
def db_session() -> Generator[Session, None, None]:
    db = get_session_local()()
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def init_db() -> None:
    from ccs_platform.db import models  # noqa: F401

    _engine = get_engine()
    settings = get_settings()

    # For PostgreSQL (production) run Alembic migrations automatically on startup.
    # This means no manual migration step or paid Render feature is needed —
    # the app always migrates itself to head before serving traffic.
    #
    # SQLite (development) keeps the existing create_all + legacy-reset path below
    # because dev DBs are often not Alembic-stamped.
    if _engine.dialect.name != "sqlite":
        cfg = AlembicConfig(str(_ALEMBIC_INI))
        cfg.set_main_option("sqlalchemy.url", settings.resolved_database_url())
        alembic_command.upgrade(cfg, "head")
        return

    # Legacy local SQLite files from pre-profile builds are optionally reset in-place.
    # In production this is disabled by default to avoid destructive startup behavior.
    if _engine.dialect.name == "sqlite":
        inspector = inspect(_engine)
        required_columns = {
            "profiles": {"id", "key", "name", "is_default"},
            "runtime_settings": {"profile_id"},
            "pdf_files": {"profile_id"},
            "statements": {"profile_id"},
            "jobs": {
                "profile_id",
                "queue_name",
                "idempotency_key",
                "attempt_count",
                "max_attempts",
                "next_retry_at",
                "last_heartbeat_at",
                "cancel_requested_at",
            },
            "schedules": {"profile_id"},
            "exports": {"profile_id"},
            "audit_events": {"profile_id"},
        }

        requires_reset = False
        for table_name, columns in required_columns.items():
            if not inspector.has_table(table_name):
                requires_reset = True
                break
            existing_columns = {column["name"] for column in inspector.get_columns(table_name)}
            if not columns.issubset(existing_columns):
                requires_reset = True
                break

        if requires_reset:
            if settings.sqlite_legacy_reset_enabled():
                logger.warning(
                    "SQLite schema mismatch detected; applying destructive legacy reset because "
                    "CCS_PLATFORM_ALLOW_LEGACY_SQLITE_RESET is enabled."
                )
                Base.metadata.drop_all(bind=_engine)
            else:
                raise RuntimeError(
                    "SQLite schema mismatch detected. Refusing destructive reset. "
                    "Run migrations (alembic upgrade head) or set "
                    "CCS_PLATFORM_ALLOW_LEGACY_SQLITE_RESET=true for an explicit one-time reset."
                )

    Base.metadata.create_all(bind=_engine)
