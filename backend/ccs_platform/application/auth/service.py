from __future__ import annotations

from dataclasses import dataclass
import os

from ccs_platform.core.settings import get_settings


@dataclass(frozen=True)
class AuthAccount:
    email: str
    login_value: str
    display_name: str
    default_profile_key: str
    role: str = "admin"


def normalize_email(email: str) -> str:
    return (email or "").strip().lower()


def _resolve_login_value(env_var: str, display_name: str) -> str:
    value = os.getenv(env_var, "").strip()
    if not value:
        settings = get_settings()
        if settings.is_production():
            raise RuntimeError(
                f"Auth credential for {display_name} is not configured. "
                f"Set the {env_var} environment variable before starting in production."
            )
    return value


_ACCOUNTS: tuple[AuthAccount, ...] = (
    AuthAccount(
        email="h_abbasi97@hotmail.com",
        login_value=_resolve_login_value("CCS_PLATFORM_LOGIN_VALUE_HUSSAIN", "Alice"),
        display_name="Alice",
        default_profile_key="alice",
    ),
    AuthAccount(
        email="bob@example.com",
        login_value=_resolve_login_value("CCS_PLATFORM_LOGIN_VALUE_BOB", "Bob"),
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
    if password != account.login_value:
        return None
    return account
