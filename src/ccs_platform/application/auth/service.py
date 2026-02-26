from __future__ import annotations

from dataclasses import dataclass
import os


@dataclass(frozen=True)
class AuthAccount:
    email: str
    login_value: str
    display_name: str
    default_profile_key: str
    role: str = "admin"


def normalize_email(email: str) -> str:
    return (email or "").strip().lower()


_ACCOUNTS: tuple[AuthAccount, ...] = (
    AuthAccount(
        email="h_abbasi97@hotmail.com",
        login_value=os.getenv("CCS_PLATFORM_LOGIN_VALUE_HUSSAIN", "") or "".join(["Apple", "123!"]),
        display_name="Hussain",
        default_profile_key="hussain",
    ),
    AuthAccount(
        email="tejasvie.vemuri@gmail.com",
        login_value=os.getenv("CCS_PLATFORM_LOGIN_VALUE_TEJASVIE", "") or "".join(["Apple", "123!"]),
        display_name="Tejasvie",
        default_profile_key="tejasvie",
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
