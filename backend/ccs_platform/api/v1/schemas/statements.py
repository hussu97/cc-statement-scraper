from __future__ import annotations

from datetime import date, datetime

from pydantic import BaseModel

from ccs_platform.db.models import ReferenceSource


class StatementOut(BaseModel):
    id: int
    bank_code: str
    statement_reference: str
    statement_reference_raw: str | None
    reference_source: ReferenceSource
    statement_date: date
    statement_period_start: date | None
    statement_period_end: date | None
    primary_card_last4: str | None
    card_holder: str | None
    card_type: str | None
    pdf_file_id: int | None
    ingested_at: datetime
    line_count: int = 0
    total_debit_aed: float = 0.0
    total_credit_aed: float = 0.0


class StatementLineOut(BaseModel):
    id: int
    statement_id: int
    line_no: int
    transaction_date: date
    transaction_time: str
    is_time_inferred: bool
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
    category: str
    category_override: str | None = None


class PaginatedStatements(BaseModel):
    total: int
    page: int
    page_size: int
    items: list[StatementOut]


class PaginatedStatementLines(BaseModel):
    total: int
    page: int
    page_size: int
    items: list[StatementLineOut]


class StatementDateUpdate(BaseModel):
    statement_date: date
