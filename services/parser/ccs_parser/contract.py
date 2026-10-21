"""Pydantic models of the parse-v1 contract (docs/contracts/parse-v1.md)."""

from __future__ import annotations

from datetime import date, time
from decimal import Decimal
from typing import Annotated, Any, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints, model_validator

# The output must satisfy the database's own constraints (X-06), so a parser bug is
# a permanent PARSE_OUTPUT_INVALID instead of a failed ingest:
#   numeric(14,2) amounts >= 0, numeric(18,8) fx_rate > 0, real calendar dates,
#   last-4 '^[0-9]{4}$', period_start <= period_end.
MIN_YEAR = 2000
MAX_YEAR = 2100
# A statement covers about a month; anything longer is a mis-read year.
MAX_STATEMENT_PERIOD_DAYS = 100
# Due dates fall weeks after the statement date (real data: 18-26 days).
MAX_DUE_DAYS_AFTER_STATEMENT = 120


def _real_date(value: str) -> str:
    parsed = date.fromisoformat(value)
    if not MIN_YEAR <= parsed.year <= MAX_YEAR:
        raise ValueError(f"year {parsed.year} is outside {MIN_YEAR}-{MAX_YEAR}")
    return value


def _real_time(value: str) -> str:
    time.fromisoformat(value)
    return value


def _positive(value: str) -> str:
    if Decimal(value) <= 0:
        raise ValueError("must be greater than zero")
    return value


# numeric(14,2): at most 12 integer digits.
Money = Annotated[str, StringConstraints(pattern=r"^\d{1,12}(\.\d+)?$")]
# Signed amount: opening/closing balances (negative = card in credit).
SignedMoney = Annotated[str, StringConstraints(pattern=r"^-?\d{1,12}(\.\d+)?$")]
# numeric(18,8): at most 10 integer digits, and the DB requires fx_rate > 0.
FxRate = Annotated[str, StringConstraints(pattern=r"^\d{1,10}(\.\d+)?$"), AfterValidator(_positive)]
IsoDate = Annotated[str, StringConstraints(pattern=r"^\d{4}-\d{2}-\d{2}$"), AfterValidator(_real_date)]
IsoTime = Annotated[str, StringConstraints(pattern=r"^\d{2}:\d{2}(:\d{2}(\.\d+)?)?$"), AfterValidator(_real_time)]
Last4 = Annotated[str, StringConstraints(pattern=r"^[0-9]{4}$")]
CountryCode = Annotated[str, StringConstraints(pattern=r"^[A-Z]{2}$")]  # ISO 3166-1 alpha-2 (X-25r)

DocumentKind = Literal["statement_pdf", "history_pdf", "account_statement_pdf"]
StatementKind = Literal["statement", "history_extract"]
Direction = Literal["debit", "credit"]
LineKind = Literal[
    "purchase", "refund", "payment", "fee", "interest", "cash_advance", "adjustment", "transfer_in", "transfer_out"
]
BankAccountKind = Literal["current", "savings"]
ReferenceSource = Literal["explicit", "fallback"]

ErrorCode = Literal[
    "UNAUTHORIZED",
    "PDF_DECRYPT_FAILED",
    "UNSUPPORTED_BANK",
    "UNSUPPORTED_LAYOUT",
    "BANK_UNDETECTED",
    "DOWNLOAD_FAILED",
    "INVALID_REQUEST",
    "PARSE_TIMEOUT",
    "PDF_TOO_LARGE",
    "PARSE_OUTPUT_INVALID",
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
    txn_time: IsoTime | None
    posting_date: IsoDate | None
    description_raw: str
    merchant_normalized: str
    amount_original: Money
    currency_original: Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
    amount_aed: Money | None
    fx_rate: FxRate | None
    direction: Direction
    kind: LineKind
    country_code: CountryCode | None
    card_last4: Last4 | None
    card_holder: str | None
    legacy_fingerprint: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]


class BankAccount(_Strict):
    """The bank account an ``account_statement_pdf`` statement is for (null on card statements)."""

    kind: BankAccountKind
    number: Annotated[str, StringConstraints(pattern=r"^[0-9]{6,34}$")]
    ref: Annotated[str, StringConstraints(pattern=r"^[0-9]{3,12}$")]  # accounts.account_ref
    iban: Annotated[str, StringConstraints(pattern=r"^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$")] | None
    product: Annotated[str, StringConstraints(min_length=1, max_length=120)]
    currency: Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]


# numeric(6,3) percentage, 0-100.
RatePct = Annotated[str, StringConstraints(pattern=r"^\d{1,3}(\.\d{1,3})?$")]


class Deposit(_Strict):
    """A fixed deposit listed in a consolidated statement: its value as of ``as_of``."""

    number: Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9-]{3,40}$")]  # holdings.external_ref
    product: Annotated[str, StringConstraints(min_length=1, max_length=80)]
    currency: Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
    rate_pct: RatePct
    maturity_on: IsoDate
    amount: Money
    as_of: IsoDate


class CardSummary(_Strict):
    """A credit card's row in a consolidated statement (a cross-check, not a statement)."""

    last4: Last4
    credit_limit: Money
    current_balance: SignedMoney
    min_due: Money
    last_statement_balance: SignedMoney
    last_statement_date: IsoDate
    due_date: IsoDate
    as_of: IsoDate


class Statement(_Strict):
    kind: StatementKind
    bank_code: str
    statement_reference: str
    reference_source: ReferenceSource | None
    statement_date: IsoDate
    period_start: IsoDate | None
    period_end: IsoDate | None
    due_date: IsoDate | None
    primary_card_last4: Last4 | None
    card_holder: str | None
    card_type: str | None
    totals: Totals
    warnings: list[str]
    metadata: dict[str, Any]
    lines: list[Line]
    account: BankAccount | None = None

    @model_validator(mode="after")
    def _dates_are_consistent(self) -> Statement:
        start = date.fromisoformat(self.period_start) if self.period_start else None
        end = date.fromisoformat(self.period_end) if self.period_end else None
        stmt = date.fromisoformat(self.statement_date)
        if start and end:
            if start > end:
                raise ValueError("period_start is after period_end")
            if self.kind == "statement" and (end - start).days > MAX_STATEMENT_PERIOD_DAYS:
                raise ValueError(f"statement period is longer than {MAX_STATEMENT_PERIOD_DAYS} days")
        if self.due_date and self.kind == "statement":
            due = date.fromisoformat(self.due_date)
            if due < stmt:
                raise ValueError("due_date is before statement_date")
            if (due - stmt).days > MAX_DUE_DAYS_AFTER_STATEMENT:
                raise ValueError(f"due_date is more than {MAX_DUE_DAYS_AFTER_STATEMENT} days after statement_date")
        return self


class ParseResponse(_Strict):
    contract_version: Literal[1]
    parser_version: str
    bank_code: str
    document_kind: DocumentKind
    statements: list[Statement] = Field(min_length=1)
    deposits: list[Deposit] = Field(default_factory=list)
    card_summaries: list[CardSummary] = Field(default_factory=list)

    @model_validator(mode="after")
    def _accounts_match_kind(self) -> ParseResponse:
        bank_statement = self.document_kind == "account_statement_pdf"
        if any((st.account is not None) != bank_statement for st in self.statements):
            raise ValueError("account is set exactly on the statements of an account_statement_pdf")
        if not bank_statement and (self.deposits or self.card_summaries):
            raise ValueError("deposits and card_summaries come only with an account_statement_pdf")
        return self


class ErrorBody(_Strict):
    code: ErrorCode
    message: str


class ErrorResponse(_Strict):
    error: ErrorBody
