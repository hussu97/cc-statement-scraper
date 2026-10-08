from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field, field_validator


class ParserError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class TransactionRecord(BaseModel):
    bank_name: str
    card_last4: str
    card_holder: str | None = None
    card_type: str | None = None
    statement_month: str
    transaction_date: date
    posting_date: date
    merchant_raw: str
    merchant_normalized: str
    country_code: str | None = None
    amount_original: float
    currency_original: str
    amount_aed: float | None = None
    fx_rate_to_aed: float | None = None
    transaction_kind: str
    category: str = "Uncategorized"
    source_pdf: str
    fingerprint: str
    ingested_at: datetime = Field(default_factory=lambda: datetime.now(UTC))

    @field_validator("statement_month")
    @classmethod
    def validate_statement_month(cls, value: str) -> str:
        if len(value) != 7 or value[4] != "-":
            raise ValueError("statement_month must be YYYY-MM")
        return value


@dataclass
class StatementParseResult:
    bank_code: str
    bank_name: str
    source_pdf: Path
    statement_month: str
    transactions: list[TransactionRecord] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
