from __future__ import annotations

from datetime import datetime
from collections.abc import Iterable
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.core.bank_config import load_app_config
from ccs_platform.db import models


BANK_CAPABILITIES: dict[str, dict[str, bool]] = {
    "FAB": {
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "ADCB": {
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "ENBD": {
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "EIB": {
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "SIB": {
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "MASHREQ": {
        "supports_multi_month": True,
        "supports_headless": True,
    },
}


def seed_banks(db: Session) -> None:
    cfg = load_app_config()

    existing_rows = {
        row.code: row
        for row in db.execute(select(models.Bank)).scalars().all()
    }
    for code, bank_cfg in cfg.banks.items():
        caps = BANK_CAPABILITIES.get(code, {})
        bank_name = bank_cfg.get("bank_name", code)
        portal_url = bank_cfg.get("portal_url")
        supports_multi = caps.get("supports_multi_month", False)
        supports_headless = caps.get("supports_headless", True)

        row = existing_rows.get(code)
        if row is None:
            db.add(
                models.Bank(
                    code=code,
                    name=bank_name,
                    supports_multi_month=supports_multi,
                    supports_headless=supports_headless,
                    portal_url=portal_url,
                )
            )
            continue

        # Keep capabilities synchronized with static adapter capability matrix.
        row.name = bank_name
        row.portal_url = portal_url
        row.supports_multi_month = supports_multi
        row.supports_headless = supports_headless


def get_enabled_banks(
    db: Session,
    requested: Iterable[str] | None = None,
    *,
    profile_id: int | None = None,
) -> list[models.Bank]:
    query = select(models.Bank)
    if profile_id is not None:
        query = (
            query.join(models.ProfileBank, models.ProfileBank.bank_code == models.Bank.code)
            .where(models.ProfileBank.profile_id == profile_id)
        )
    query = query.order_by(models.Bank.code.asc())
    banks = db.execute(query).scalars().all()
    if not requested:
        return banks

    requested_set = {token.upper().strip() for token in requested if token.strip()}
    return [bank for bank in banks if bank.code.upper() in requested_set]


def current_month_token(*, timezone: str = "Asia/Dubai") -> str:
    now = datetime.now(ZoneInfo(timezone))
    return f"{now.year:04d}-{now.month:02d}"


