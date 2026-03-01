from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
import logging

import bcrypt

from ccs_platform.core.settings import get_settings

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AuthAccount:
    email: str
    password_hash: str  # bcrypt hash stored in CCS_PLATFORM_LOGIN_HASH_<NAME>
    display_name: str
    default_profile_key: str
    role: str = "admin"


def normalize_email(email: str) -> str:
    return (email or "").strip().lower()


@lru_cache(maxsize=1)
def _build_accounts() -> tuple[AuthAccount, ...]:
    settings = get_settings()
    if settings.is_production():
        if not settings.login_hash_hussain:
            raise RuntimeError(
                "Auth credential hash for Alice is not configured. "
                "Set CCS_PLATFORM_LOGIN_HASH_HUSSAIN before starting in production. "
                "Generate a hash with: python -m ccs_platform.cli hash-password"
            )
        if not settings.login_hash_bob:
            raise RuntimeError(
                "Auth credential hash for Bob is not configured. "
                "Set CCS_PLATFORM_LOGIN_HASH_BOB before starting in production. "
                "Generate a hash with: python -m ccs_platform.cli hash-password"
            )
    return (
        AuthAccount(
            email="h_abbasi97@hotmail.com",
            password_hash=settings.login_hash_hussain,
            display_name="Alice",
            default_profile_key="alice",
        ),
        AuthAccount(
            email="bob@example.com",
            password_hash=settings.login_hash_bob,
            display_name="Bob",
            default_profile_key="bob",
        ),
    )


def list_accounts() -> tuple[AuthAccount, ...]:
    return _build_accounts()


def get_account_by_email(email: str) -> AuthAccount | None:
    return {normalize_email(a.email): a for a in _build_accounts()}.get(normalize_email(email))


def authenticate_credentials(*, email: str, password: str) -> AuthAccount | None:
    account = get_account_by_email(email)
    if account is None:
        return None
    if not account.password_hash:
        # Dev fallback: no hash configured, deny login (set CCS_PLATFORM_LOGIN_HASH_* to enable)
        return None
    try:
        if not bcrypt.checkpw(password.encode(), account.password_hash.encode()):
            return None
    except Exception:
        logger.exception("bcrypt.checkpw failed for %s — possible corrupted hash", account.email)
        return None
    return account
