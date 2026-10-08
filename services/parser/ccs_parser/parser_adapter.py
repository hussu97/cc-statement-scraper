from __future__ import annotations

import re
from datetime import date, datetime
from pathlib import Path

from ccs_parser.domain.parsing.models import ParserError, StatementParseResult, TransactionRecord
from ccs_parser.banks import parse_statement_for_bank
from ccs_parser.domain.parsing.utils import statement_month_from_date
from ccs_parser.domain.statements.types import ParsedLine, ParsedStatement


_EMPTY_STATEMENT_MONTH = "1970-01"

_REF_PATTERNS = [
    re.compile(
        r"\b(?:statement\s*(?:no|number|reference|ref)|ref(?:erence)?)\b\s*[:#-]?\s*([A-Z0-9\-/]*\d[A-Z0-9\-/]{5,})\b",
        re.IGNORECASE,
    ),
]


def _parse_iso_date(raw: str | None) -> date | None:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw).date()
    except ValueError:
        try:
            return date.fromisoformat(raw)
        except ValueError:
            return None


def _statement_date_from_result(result: StatementParseResult) -> date:
    statement_date = _parse_iso_date(str(result.metadata.get("statement_date")) if result.metadata else None)
    if statement_date:
        return statement_date

    tx_dates = [tx.posting_date for tx in result.transactions]
    if tx_dates:
        return max(tx_dates)

    month = result.statement_month
    # "1970-01" is the legacy parsers' sentinel for "no statement date and no
    # transactions" -- the legacy backend turned it into 1970-01-01. Treat it as
    # undeterminable instead.
    if month and len(month) == 7 and month != _EMPTY_STATEMENT_MONTH:
        # use first day as deterministic fallback for empty statements
        try:
            return date.fromisoformat(f"{month}-01")
        except ValueError:
            pass
    # Legacy fell back to date.today() here; never invent a statement date.
    raise ParserError(
        "UNSUPPORTED_LAYOUT",
        f"{result.bank_code}: could not determine the statement date from the PDF.",
    )


def _extract_reference_from_name(name: str) -> str | None:
    upper = Path(name).name.upper()
    for pattern in _REF_PATTERNS:
        match = pattern.search(upper)
        if match:
            return match.group(1).strip()
    return None


def _extract_reference(result: StatementParseResult, *, source_filename: str | None = None) -> str | None:
    if result.metadata:
        for key in ["statement_reference", "statement_ref", "reference"]:
            value = result.metadata.get(key)
            if value is None:
                continue
            normalized = str(value).strip()
            if normalized:
                return normalized

    if source_filename:
        return _extract_reference_from_name(source_filename)

    return None


def _direction_for_tx(tx: TransactionRecord) -> str:
    amount = tx.amount_aed if tx.amount_aed is not None else tx.amount_original
    if amount < 0:
        return "credit"
    return "debit"


def _convert_tx(idx: int, tx: TransactionRecord) -> ParsedLine:
    return ParsedLine(
        line_no=idx,
        transaction_date=tx.transaction_date,
        transaction_time=None,
        posting_date=tx.posting_date,
        merchant_raw=tx.merchant_raw,
        merchant_normalized=tx.merchant_normalized,
        amount_original=float(tx.amount_original),
        currency_original=tx.currency_original,
        amount_aed=float(tx.amount_aed) if tx.amount_aed is not None else None,
        direction=_direction_for_tx(tx),
        transaction_kind=tx.transaction_kind,
        country_code=tx.country_code,
        card_last4=tx.card_last4,
        fingerprint=tx.fingerprint,
        raw={
            "statement_month": tx.statement_month,
            "source_pdf": tx.source_pdf,
            "ingested_at": tx.ingested_at.isoformat(),
        },
        fx_rate_to_aed=tx.fx_rate_to_aed,
        card_holder=tx.card_holder,
    )


def _build_parsed_statement(
    result: StatementParseResult,
    pdf_path: Path,
    *,
    source_filename: str | None = None,
) -> ParsedStatement:
    statement_date = _statement_date_from_result(result)
    period_end = _parse_iso_date(str(result.metadata.get("statement_period_end")) if result.metadata else None)
    period_start = _parse_iso_date(str(result.metadata.get("statement_period_start")) if result.metadata else None)

    # Ensure statement_month continuity for empty metadata fallback use.
    if not period_end and result.statement_month:
        try:
            period_end = date.fromisoformat(f"{result.statement_month}-01")
        except ValueError:
            period_end = None

    primary_last4 = None
    card_holder = None
    card_type = None
    if result.transactions:
        first = result.transactions[0]
        primary_last4 = first.card_last4
        card_holder = first.card_holder
        card_type = first.card_type

    if result.metadata:
        primary_last4 = str(result.metadata.get("card_last4") or result.metadata.get("main_last4") or primary_last4 or "").strip() or None
        card_holder = str(result.metadata.get("card_holder") or result.metadata.get("main_holder") or card_holder or "").strip() or None
        card_type = str(result.metadata.get("card_type") or card_type or "").strip() or None

    lines = [_convert_tx(idx + 1, tx) for idx, tx in enumerate(result.transactions)]

    # Keep a deterministic marker for downstream fallback identity generation.
    metadata = dict(result.metadata or {})
    metadata["statement_month"] = statement_month_from_date(statement_date)
    metadata["source_pdf"] = str(pdf_path)

    return ParsedStatement(
        bank_code=result.bank_code,
        statement_reference_raw=_extract_reference(result, source_filename=source_filename),
        statement_date=statement_date,
        statement_period_start=period_start,
        statement_period_end=period_end,
        primary_card_last4=primary_last4,
        card_holder=card_holder,
        card_type=card_type,
        lines=lines,
        warnings=list(result.warnings),
        metadata=metadata,
    )


def parse_statement_pdf(
    bank_code: str,
    pdf_path: Path,
    *,
    source_filename: str | None = None,
    runtime_settings: dict[str, str] | None = None,
) -> ParsedStatement | list[ParsedStatement]:
    result = parse_statement_for_bank(bank_code, pdf_path, runtime_settings)

    if isinstance(result, list):
        return [
            _build_parsed_statement(r, pdf_path, source_filename=source_filename)
            for r in result
        ]

    return _build_parsed_statement(result, pdf_path, source_filename=source_filename)
