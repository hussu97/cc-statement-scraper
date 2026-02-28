"""Shared pytest fixtures for the CCS platform test suite."""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from dotenv import dotenv_values
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from ccs_platform.core.settings import PlatformSettings, clear_settings_caches
from ccs_platform.db.base import Base
from ccs_platform.db import models

# ---------------------------------------------------------------------------
# Load only the auth credential hashes from backend/.env into process env so
# that pydantic-settings resolves login_hash_hussain / login_hash_tejasvie
# correctly in tests that exercise real login flows.
# We intentionally skip CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY so that
# tests which exercise the "no key" code path are not polluted.
# ---------------------------------------------------------------------------
_BACKEND_ENV = Path(__file__).resolve().parents[1] / ".env"
if _BACKEND_ENV.exists():
    _AUTH_KEYS = {
        "CCS_PLATFORM_LOGIN_HASH_HUSSAIN",
        "CCS_PLATFORM_LOGIN_HASH_TEJASVIE",
    }
    for _k, _v in dotenv_values(_BACKEND_ENV).items():
        if _k in _AUTH_KEYS and _v:
            os.environ.setdefault(_k, _v)


# ---------------------------------------------------------------------------
# Cache management
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _clear_caches():
    """Clear all settings caches before and after each test."""
    clear_settings_caches()
    yield
    clear_settings_caches()


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
