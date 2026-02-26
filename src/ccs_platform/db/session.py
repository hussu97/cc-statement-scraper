from __future__ import annotations

from contextlib import contextmanager
from typing import Generator

from sqlalchemy import create_engine
from sqlalchemy import inspect
from sqlalchemy.orm import Session, sessionmaker

from ccs_platform.core.settings import get_settings
from ccs_platform.db.base import Base


def _engine_kwargs(database_url: str) -> dict:
    kwargs: dict = {"future": True, "pool_pre_ping": True}
    if database_url.startswith("sqlite"):
        kwargs["connect_args"] = {"check_same_thread": False}
    return kwargs


settings = get_settings()
engine = create_engine(settings.database_url, **_engine_kwargs(settings.database_url))
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@contextmanager
def db_session() -> Generator[Session, None, None]:
    db = SessionLocal()
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

    # Legacy local SQLite files from pre-profile builds are reset in-place.
    if engine.dialect.name == "sqlite":
        inspector = inspect(engine)
        required_columns = {
            "profiles": {"id", "key", "name", "is_default"},
            "runtime_settings": {"profile_id"},
            "pdf_files": {"profile_id"},
            "statements": {"profile_id"},
            "jobs": {"profile_id"},
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
            Base.metadata.drop_all(bind=engine)

    Base.metadata.create_all(bind=engine)
