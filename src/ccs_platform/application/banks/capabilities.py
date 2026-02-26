from __future__ import annotations

from datetime import date, datetime
import re
from collections.abc import Iterable
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.core.bank_config import load_app_config
from ccs_platform.db import models


MONTH_TOKEN_PATTERN = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")
MIN_SCRAPE_MONTH = date(2024, 1, 1)

BANK_CAPABILITIES: dict[str, dict[str, bool]] = {
    "FAB": {
        "supports_historical_month_selection": True,
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "ADCB": {
        "supports_historical_month_selection": True,
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "ENBD": {
        "supports_historical_month_selection": True,
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "EIB": {
        "supports_historical_month_selection": True,
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "SIB": {
        "supports_historical_month_selection": True,
        "supports_multi_month": True,
        "supports_headless": True,
    },
    "MASHREQ": {
        "supports_historical_month_selection": True,
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
        supports_historical = caps.get("supports_historical_month_selection", False)
        supports_multi = caps.get("supports_multi_month", False)
        supports_headless = caps.get("supports_headless", True)

        row = existing_rows.get(code)
        if row is None:
            db.add(
                models.Bank(
                    code=code,
                    name=bank_name,
                    supports_historical_month_selection=supports_historical,
                    supports_multi_month=supports_multi,
                    supports_headless=supports_headless,
                    portal_url=portal_url,
                )
            )
            continue

        # Keep capabilities synchronized with static adapter capability matrix.
        row.name = bank_name
        row.portal_url = portal_url
        row.supports_historical_month_selection = supports_historical
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


def parse_month_token(value: str) -> date:
    token = (value or "").strip()
    if not MONTH_TOKEN_PATTERN.match(token):
        raise ValueError(f"Invalid month token: {value!r}. Expected YYYY-MM.")
    return date(int(token[:4]), int(token[5:7]), 1)


def month_token(value: date) -> str:
    return f"{value.year:04d}-{value.month:02d}"


def month_tokens_between(start: str, end: str) -> list[str]:
    start_date = parse_month_token(start)
    end_date = parse_month_token(end)
    if start_date > end_date:
        raise ValueError("month_from must be <= month_to")

    tokens: list[str] = []
    current = start_date
    while current <= end_date:
        tokens.append(month_token(current))
        if current.month == 12:
            current = date(current.year + 1, 1, 1)
        else:
            current = date(current.year, current.month + 1, 1)
    return tokens


def validate_month_bounds(months: list[str], *, timezone: str = "Asia/Dubai") -> list[str]:
    max_month = parse_month_token(current_month_token(timezone=timezone))
    normalized: list[str] = []
    seen: set[str] = set()

    for token in months:
        item = token.strip()
        if item.lower() == "latest":
            item = current_month_token(timezone=timezone)
        parsed = parse_month_token(item)
        if parsed < MIN_SCRAPE_MONTH:
            raise ValueError(f"Month {item} is before supported minimum {month_token(MIN_SCRAPE_MONTH)}")
        if parsed > max_month:
            raise ValueError(f"Month {item} is after current month {month_token(max_month)}")
        item_norm = month_token(parsed)
        if item_norm in seen:
            continue
        seen.add(item_norm)
        normalized.append(item_norm)

    if not normalized:
        normalized = [month_token(max_month)]
    return normalized


def supports_multi_month(bank: models.Bank) -> bool:
    code = bank.code.upper()
    static_caps = BANK_CAPABILITIES.get(code, {})
    return bool(bank.supports_multi_month or static_caps.get("supports_multi_month", False))


def supports_historical_month_selection(bank: models.Bank) -> bool:
    code = bank.code.upper()
    static_caps = BANK_CAPABILITIES.get(code, {})
    return bool(
        bank.supports_historical_month_selection
        or static_caps.get("supports_historical_month_selection", False)
    )


def resolve_requested_months(
    *,
    months: list[str] | None = None,
    month_from: str | None = None,
    month_to: str | None = None,
    timezone: str = "Asia/Dubai",
) -> list[str]:
    if month_from or month_to:
        from_token = (month_from or month_to or "").strip()
        to_token = (month_to or month_from or "").strip()
        if not from_token or not to_token:
            raise ValueError("Both month_from and month_to must be provided")
        expanded = month_tokens_between(from_token, to_token)
        return validate_month_bounds(expanded, timezone=timezone)

    raw = [token for token in (months or []) if token and token.strip()]
    if not raw:
        raw = [current_month_token(timezone=timezone)]
    return validate_month_bounds(raw, timezone=timezone)


def build_bank_scrape_config(bank_code: str, month: str) -> dict[str, str | int]:
    target = parse_month_token(month)
    payload: dict[str, str | int] = {
        "requested_month": month_token(target),
    }

    code = bank_code.upper()
    if code in {"ENBD", "EIB"}:
        key_prefix = "enbd" if code == "ENBD" else "eib"
        payload.update(
            {
                f"{key_prefix}_statement_year": target.year,
                f"{key_prefix}_statement_month": target.month,
            }
        )
    elif code == "FAB":
        payload.update(
            {
                "fab_statement_period": month_token(target),
            }
        )
    elif code == "ADCB":
        payload.update(
            {
                "adcb_statement_period": month_token(target),
            }
        )
    elif code == "SIB":
        payload.update(
            {
                "sib_statement_period": month_token(target),
                "sib_statement_year": target.year,
                "sib_statement_month": target.month,
            }
        )
    elif code == "MASHREQ":
        payload.update(
            {
                "mashreq_statement_period": month_token(target),
                "mashreq_statement_year": target.year,
                "mashreq_statement_month": target.month,
            }
        )
    return payload


def is_month_supported(bank: models.Bank, month: str, *, timezone: str = "Asia/Dubai") -> bool:
    token = (month or "").strip().lower()
    if token == "latest":
        return True
    if supports_historical_month_selection(bank):
        return True
    try:
        month_value = parse_month_token(month)
    except ValueError:
        return False
    current_value = parse_month_token(current_month_token(timezone=timezone))
    return month_value == current_value
