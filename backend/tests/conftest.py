"""Shared pytest fixtures for the CCS platform test suite."""

from __future__ import annotations

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db import Base
from ccs_platform.db import models


# ---------------------------------------------------------------------------
# Database fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def sqlite_engine():
    """In-memory SQLite engine with all tables created."""
    engine = create_engine("sqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    yield engine
    engine.dispose()


@pytest.fixture()
def db_session(sqlite_engine) -> Session:
    """SQLAlchemy session backed by the in-memory SQLite engine.

    The session is yielded open; callers should ``db.flush()`` or
    ``db.commit()`` as needed.  The fixture does not commit after the test so
    that each test starts with a clean slate via a fresh engine.
    """
    SessionLocal = sessionmaker(bind=sqlite_engine, future=True)
    with SessionLocal() as session:
        yield session


# ---------------------------------------------------------------------------
# Seed helpers
# ---------------------------------------------------------------------------


@pytest.fixture()
def sample_profile(db_session: Session) -> models.Profile:
    """A default Profile row, flushed but not committed."""
    profile = models.Profile(key="test_user", name="Test User", is_default=True)
    db_session.add(profile)
    db_session.flush()
    return profile


@pytest.fixture()
def sample_banks(db_session: Session) -> list[models.Bank]:
    """FAB and ENBD Bank rows, flushed but not committed."""
    banks = [
        models.Bank(
            code="FAB",
            name="FAB",
            supports_historical_month_selection=False,
            supports_multi_month=False,
            supports_headless=True,
        ),
        models.Bank(
            code="ENBD",
            name="ENBD",
            supports_historical_month_selection=True,
            supports_multi_month=True,
            supports_headless=True,
        ),
    ]
    db_session.add_all(banks)
    db_session.flush()
    return banks


# ---------------------------------------------------------------------------
# Settings fixture
# ---------------------------------------------------------------------------


@pytest.fixture()
def dev_settings() -> PlatformSettings:
    """Default development PlatformSettings (no env file required)."""
    return PlatformSettings(
        environment="development",
        require_login=False,
        database_url="sqlite:///./test.db",
    )
