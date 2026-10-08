"""Pydantic models of the parse-v1 contract (docs/contracts/parse-v1.md)."""

from __future__ import annotations

from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

Money = Annotated[str, StringConstraints(pattern=r"^\d+(\.\d+)?$")]
# Signed amount: opening/closing balances (negative = card in credit).
SignedMoney = Annotated[str, StringConstraints(pattern=r"^-?\d+(\.\d+)?$")]
IsoDate = Annotated[str, StringConstraints(pattern=r"^\d{4}-\d{2}-\d{2}$")]

DocumentKind = Literal["statement_pdf", "history_pdf"]
StatementKind = Literal["statement", "history_extract"]
Direction = Literal["debit", "credit"]
LineKind = Literal["purchase", "refund", "payment", "fee", "interest", "cash_advance", "adjustment"]
ReferenceSource = Literal["explicit", "fallback"]

ErrorCode = Literal[
    "UNAUTHORIZED",
    "PDF_DECRYPT_FAILED",
    "UNSUPPORTED_BANK",
    "UNSUPPORTED_LAYOUT",
    "BANK_UNDETECTED",
    "DOWNLOAD_FAILED",
    "INVALID_REQUEST",
    "INTERNAL_ERROR",
]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ParseRequest(BaseModel):
    document_url: Annotated[str, StringConstraints(min_length=1, max_length=8192)]
    filename: str | None = None
    bank_code_hint: str | None = None
    settings: dict[str, str | None] = Field(default_factory=dict)


class Totals(_Strict):
    opening_balance: SignedMoney | None
    closing_balance: SignedMoney | None
    total_debits: Money | None
    total_credits: Money | None
    min_due: Money | None
    credit_limit: Money | None


class Line(_Strict):
    line_no: int = Field(ge=1)
    txn_date: IsoDate
    txn_time: str | None
    posting_date: IsoDate | None
    description_raw: str
    merchant_normalized: str
    amount_original: Money
    currency_original: Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
    amount_aed: Money | None
    fx_rate: Money | None
    direction: Direction
    kind: LineKind
    country_code: str | None
    card_last4: str | None
    card_holder: str | None
    legacy_fingerprint: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]


class Statement(_Strict):
    kind: StatementKind
    bank_code: str
    statement_reference: str
    reference_source: ReferenceSource | None
    statement_date: IsoDate
    period_start: IsoDate | None
    period_end: IsoDate | None
    due_date: IsoDate | None
    primary_card_last4: str | None
    card_holder: str | None
    card_type: str | None
    totals: Totals
    warnings: list[str]
    metadata: dict[str, Any]
    lines: list[Line]


class ParseResponse(_Strict):
    contract_version: Literal[1]
    parser_version: str
    bank_code: str
    document_kind: DocumentKind
    statements: list[Statement] = Field(min_length=1)


class ErrorBody(_Strict):
    code: ErrorCode
    message: str


class ErrorResponse(_Strict):
    error: ErrorBody
