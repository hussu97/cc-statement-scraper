from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, time
from typing import Any


@dataclass
class ParsedLine:
    line_no: int
    transaction_date: date
    transaction_time: time | None
    posting_date: date | None
    merchant_raw: str
    merchant_normalized: str
    amount_original: float
    currency_original: str
    amount_aed: float | None
    direction: str
    transaction_kind: str
    country_code: str | None
    card_last4: str | None
    fingerprint: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class ParsedStatement:
    bank_code: str
    statement_reference_raw: str | None
    statement_date: date
    statement_period_start: date | None
    statement_period_end: date | None
    primary_card_last4: str | None
    card_holder: str | None
    card_type: str | None
    lines: list[ParsedLine]
    warnings: list[str] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class StatementIdentity:
    bank_code: str
    statement_reference: str
    statement_date: date
    reference_source: str
