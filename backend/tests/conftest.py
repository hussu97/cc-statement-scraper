"""Shared pytest fixtures for the CCS platform test suite."""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from dotenv import dotenv_values
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

import ccs_platform.core.settings as _settings_mod
from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db import Base
from ccs_platform.db import models

# ---------------------------------------------------------------------------
# Prevent backend/.env from being loaded by get_settings() during tests.
# This ensures local secrets (encryption key, session key, etc.) never leak
# into tests that use monkeypatch to control those values.  The flag is set
# before any test module is imported so it can never be bypassed by
# monkeypatch.setenv("CCS_PLATFORM_ENVIRONMENT", ...).
# ---------------------------------------------------------------------------
_settings_mod._SUPPRESS_ENV_FILE = True
_settings_mod.get_settings.cache_clear()

# ---------------------------------------------------------------------------
# Load only the auth credential hashes from backend/.env into process env so
# that os.getenv("CCS_PLATFORM_LOGIN_HASH_*") resolves correctly in tests
# (auth/service.py reads these via os.getenv, not via pydantic-settings).
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
