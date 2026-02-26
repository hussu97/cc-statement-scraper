from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class AuthAccount:
    email: str
    password: str
    display_name: str
    default_profile_key: str
    role: str = "admin"


def normalize_email(email: str) -> str:
    return (email or "").strip().lower()


_ACCOUNTS: tuple[AuthAccount, ...] = (
    AuthAccount(
        email="h_abbasi97@hotmail.com",
        password="Apple123!",
        display_name="Alice",
        default_profile_key="alice",
    ),
    AuthAccount(
        email="bob@example.com",
        password="Apple123!",
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
    if password != account.password:
        return None
    return account
