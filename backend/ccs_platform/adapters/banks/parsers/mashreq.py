from __future__ import annotations

from datetime import date, datetime
import re
from pathlib import Path

import pdfplumber

from ccs_platform.domain.parsing.models import StatementParseResult, TransactionRecord
from ccs_platform.domain.parsing.utils import (
    classify_transaction_kind,
    fingerprint_for,
    merchant_normalize,
    parse_amount,
    statement_month_from_date,
)


BANK_CODE = "MASHREQ"
BANK_NAME = "Mashreq Bank"

_DATE_TOKEN = r"(?:\d{1,2}[/-]\d{1,2}(?:[/-](?:\d{4}|\d{2}))?|\d{1,2}\s+[A-Za-z]{3,9}\s+(?:\d{4}|\d{2}))"
_ROW_RE_SHORT = re.compile(
    r"^(?P<txn_date>\d{1,2}[/-]\d{1,2})\s+"
    r"(?P<posting_date>\d{1,2}[/-]\d{1,2})\s+"
    r"(?P<description>.+?)\s+"
    r"(?P<reference>[A-Z0-9]{8,})\s+"
    r"(?:(?P<currency>[A-Z]{3})\s+)?"
    r"(?P<amount>[+-]?\d[\d,]*\.\d{2})(?P<suffix>\s*(?:CR|DR|-))?$",
    re.IGNORECASE,
)
_ROW_RE = re.compile(
    rf"^(?P<txn_date>{_DATE_TOKEN})\s+"
    rf"(?:(?P<posting_date>{_DATE_TOKEN})\s+)?"
    r"(?P<description>.+?)\s+"
    r"(?:(?P<reference>[A-Z0-9]{8,})\s+)?"
    r"(?:(?P<currency>[A-Z]{3})\s+)?"
    r"(?P<amount>[+-]?\d[\d,]*\.\d{2})(?P<suffix>\s*(?:CR|DR|-))?$",
    re.IGNORECASE,
)

_STATEMENT_PERIOD_RE = re.compile(
    rf"(?:statement\s*period|period)\s*[:#-]?\s*(?P<start>{_DATE_TOKEN})\s*(?:to|-)\s*(?P<end>{_DATE_TOKEN})",
    re.IGNORECASE,
)
_STATEMENT_DATE_RE = re.compile(
    rf"(?:statement\s*date|date\s*of\s*statement|cycle\s*date)\s*[:#-]?\s*(?P<value>{_DATE_TOKEN})",
    re.IGNORECASE,
)
_CARD_LAST4_RE = re.compile(
    r"(?:card\s*(?:number|no\.?)?|account\s*(?:number|no\.?)?)\D*(?:\d{4}[\s\-]*){0,3}(\d{4})",
    re.IGNORECASE,
)
_CARD_MASK_RE = re.compile(r"(?:\*{2,}|X{2,})[\s\-]*(\d{4})")
_CARD_HOLDER_RE = re.compile(
    r"(?:cardholder|card holder|name)\s*[:#-]?\s*([A-Z][A-Z\s.'-]{2,})",
    re.IGNORECASE,
)
_STATEMENT_REF_RE = re.compile(
    r"\b(?:statement\s*(?:no|number|reference|ref)|ref(?:erence)?)\b\s*[:#-]?\s*([A-Z0-9\-/]*\d[A-Z0-9\-/]{5,})\b",
    re.IGNORECASE,
)
_IGNORE_PATTERNS = (
    re.compile(r"^\s*page\s+\d+\s+of\s+\d+\s*$", re.IGNORECASE),
    re.compile(r"^\s*transaction\s+date\b", re.IGNORECASE),
    re.compile(r"^\s*sent\s+on\b", re.IGNORECASE),
    re.compile(r"^\s*description\b", re.IGNORECASE),
    re.compile(r"^\s*amount\b", re.IGNORECASE),
    re.compile(r"^\s*currency\b", re.IGNORECASE),
    re.compile(r"^\s*statement\s+summary\b", re.IGNORECASE),
)


def _parse_flexible_date(raw: str) -> date | None:
    token = raw.strip()
    for fmt in (
        "%d/%m/%Y",
        "%d/%m/%y",
        "%d-%m-%Y",
        "%d-%m-%y",
        "%d %b %Y",
        "%d %B %Y",
        "%d %b %y",
        "%d %B %y",
    ):
        try:
            return datetime.strptime(token, fmt).date()
        except Exception:  # noqa: BLE001
            continue
    return None


def _parse_day_month(raw: str, *, anchor: date | None) -> date | None:
    token = raw.strip()
    match = re.match(r"^(?P<day>\d{1,2})[/-](?P<month>\d{1,2})$", token)
    if not match:
        return _parse_flexible_date(token)

    day = int(match.group("day"))
    month = int(match.group("month"))
    if day < 1 or day > 31 or month < 1 or month > 12:
        return None

    base_year = anchor.year if anchor else datetime.now().year
    # Statement date is the closing date; transactions with month greater than
    # statement month belong to the previous year (e.g., Dec rows in Jan statement).
    if anchor and month > anchor.month:
        base_year -= 1

    try:
        return date(base_year, month, day)
    except ValueError:
        return None


def _extract_statement_reference(lines: list[str]) -> str | None:
    for line in lines:
        match = _STATEMENT_REF_RE.search(line)
        if match:
            return match.group(1).strip()
    return None


def _is_ignored_line(line: str) -> bool:
    return any(pattern.search(line) for pattern in _IGNORE_PATTERNS)


def _extract_country_code(description: str) -> str | None:
    tokens = description.split()
    if not tokens:
        return None
    maybe = tokens[-1].strip().upper()
    if len(maybe) == 3 and maybe.isalpha():
        return maybe
    return None


def parse_mashreq_statement(pdf_path: str | Path) -> StatementParseResult:
    path = Path(pdf_path)
    lines: list[str] = []

    with pdfplumber.open(str(path)) as pdf:
        for page in pdf.pages:
            extracted = page.extract_text() or ""
            page_lines = [line.strip() for line in extracted.splitlines() if line.strip()]
            lines.extend(page_lines)

    statement_date: date | None = None
    period_start: date | None = None
    period_end: date | None = None
    card_last4 = "0000"
    card_holder: str | None = None
    card_type: str | None = "Credit Card"

    transactions: list[TransactionRecord] = []
    warnings: list[str] = []

    for line in lines:
        if _is_ignored_line(line):
            continue

        if statement_date is None:
            statement_date_match = _STATEMENT_DATE_RE.search(line)
            if statement_date_match:
                parsed_date = _parse_flexible_date(statement_date_match.group("value"))
                if parsed_date:
                    statement_date = parsed_date
                    period_end = parsed_date

        period_match = _STATEMENT_PERIOD_RE.search(line)
        if period_match:
            start = _parse_flexible_date(period_match.group("start"))
            end = _parse_flexible_date(period_match.group("end"))
            if start:
                period_start = start
            if end:
                period_end = end
                if statement_date is None:
                    statement_date = end

        if card_holder is None:
            holder_match = _CARD_HOLDER_RE.search(line)
            if holder_match:
                holder_candidate = " ".join(holder_match.group(1).split())
                if holder_candidate and holder_candidate.upper() == holder_candidate:
                    card_holder = holder_candidate

        if card_last4 == "0000":
            card_match = _CARD_LAST4_RE.search(line)
            if card_match:
                card_last4 = card_match.group(1)
            else:
                masked_match = _CARD_MASK_RE.search(line)
                if masked_match:
                    card_last4 = masked_match.group(1)

        row_match = _ROW_RE_SHORT.match(line) or _ROW_RE.match(line)
        if not row_match:
            continue

        txn_date = _parse_day_month(row_match.group("txn_date"), anchor=statement_date or period_end)
        if txn_date is None:
            continue

        posting_token = row_match.group("posting_date")
        posting_date = (
            _parse_day_month(posting_token, anchor=statement_date or period_end)
            if posting_token
            else txn_date
        )
        if posting_date is None:
            posting_date = txn_date

        description = row_match.group("description").strip()
        if not description:
            continue

        currency = (row_match.group("currency") or "AED").upper().strip()
        amount_signed = parse_amount(row_match.group("amount"))
        suffix = (row_match.group("suffix") or "").strip().upper()
        # MASHREQ marks credits with a trailing " -" as well as with "CR".
        if suffix in {"CR", "-"} and amount_signed > 0:
            amount_signed = -amount_signed
        elif suffix == "DR" and amount_signed < 0:
            amount_signed = abs(amount_signed)

        merchant_norm = merchant_normalize(description)
        kind = classify_transaction_kind(merchant_norm, amount_signed)
        if kind in {"payment", "refund"} and amount_signed > 0:
            amount_signed = -amount_signed

        statement_month = statement_month_from_date(statement_date or period_end or posting_date)
        fingerprint = fingerprint_for(
            BANK_NAME,
            card_last4,
            posting_date,
            amount_signed,
            merchant_norm,
        )

        transactions.append(
            TransactionRecord(
                bank_name=BANK_NAME,
                card_last4=card_last4,
                card_holder=card_holder,
                card_type=card_type,
                statement_month=statement_month,
                transaction_date=txn_date,
                posting_date=posting_date,
                merchant_raw=description,
                merchant_normalized=merchant_norm,
                country_code=_extract_country_code(description),
                amount_original=amount_signed,
                currency_original=currency,
                amount_aed=amount_signed if currency == "AED" else None,
                fx_rate_to_aed=1.0 if currency == "AED" else None,
                transaction_kind=kind,
                source_pdf=str(path),
                fingerprint=fingerprint,
            )
        )

    if not transactions:
        warnings.append("No MASHREQ transaction rows matched expected pattern")

    if statement_date is None and transactions:
        statement_date = max(tx.posting_date for tx in transactions)
        period_end = statement_date
        warnings.append("Statement date not detected; using max posting date")

    if period_end is None and statement_date is not None:
        period_end = statement_date

    if period_start is None and period_end is not None:
        period_start = period_end.replace(day=1)

    statement_month = (
        statement_month_from_date(period_end or statement_date)
        if (period_end or statement_date)
        else (transactions[0].statement_month if transactions else "1970-01")
    )
    if transactions and statement_month:
        for tx in transactions:
            tx.statement_month = statement_month

    return StatementParseResult(
        bank_code=BANK_CODE,
        bank_name=BANK_NAME,
        source_pdf=path,
        statement_month=statement_month,
        transactions=transactions,
        warnings=warnings,
        metadata={
            "card_last4": card_last4,
            "card_holder": card_holder,
            "card_type": card_type,
            "statement_date": statement_date.isoformat() if statement_date else None,
            "statement_period_start": period_start.isoformat() if period_start else None,
            "statement_period_end": period_end.isoformat() if period_end else None,
            "statement_reference": _extract_statement_reference(lines),
        },
    )
