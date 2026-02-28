from __future__ import annotations

from dataclasses import dataclass
import os

import bcrypt

from ccs_platform.core.settings import get_settings


@dataclass(frozen=True)
class AuthAccount:
    email: str
    password_hash: str  # bcrypt hash stored in CCS_PLATFORM_LOGIN_HASH_<NAME>
    display_name: str
    default_profile_key: str
    role: str = "admin"


def normalize_email(email: str) -> str:
    return (email or "").strip().lower()


def _resolve_login_hash(env_var: str, display_name: str) -> str:
    value = os.getenv(env_var, "").strip()
    if not value:
        settings = get_settings()
        if settings.is_production():
            raise RuntimeError(
                f"Auth credential hash for {display_name} is not configured. "
                f"Set the {env_var} environment variable before starting in production. "
                f"Generate a hash with: python -m ccs_platform.cli hash-password"
            )
    return value


_ACCOUNTS: tuple[AuthAccount, ...] = (
    AuthAccount(
        email="h_abbasi97@hotmail.com",
        password_hash=_resolve_login_hash("CCS_PLATFORM_LOGIN_HASH_HUSSAIN", "Alice"),
        display_name="Alice",
        default_profile_key="alice",
    ),
    AuthAccount(
        email="bob@example.com",
        password_hash=_resolve_login_hash("CCS_PLATFORM_LOGIN_HASH_BOB", "Bob"),
        display_name="Bob",
        default_profile_key="bob",
    ),
)

_ACCOUNT_BY_EMAIL = {normalize_email(account.email): account for account in _ACCOUNTS}


def list_accounts() -> tuple[AuthAccount, ...]:
    return _ACCOUNTS


def get_account_by_email(email: str) -> AuthAccount | None:
    return _ACCOUNT_BY_EMAIL.get(normalize_email(email))


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
        return None
    return account
