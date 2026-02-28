from __future__ import annotations

import re
from datetime import date
from pathlib import Path

import pdfplumber

from ccs_platform.domain.parsing.models import StatementParseResult, TransactionRecord
from ccs_platform.domain.parsing.utils import (
    classify_transaction_kind,
    extract_last4_masked,
    fingerprint_for,
    merchant_normalize,
    parse_amount,
    parse_date,
    statement_month_from_date,
)

BANK_CODE = "FAB"
BANK_NAME = "First Abu Dhabi Bank"

_ROW_RE = re.compile(
    r"^(?P<txn_date>\d{2}-\d{2}-\d{4})\s+"
    r"(?P<posting_date>\d{2}-\d{2}-\d{4})\s+"
    r"(?P<description>.+?)\s+"
    r"(?P<currency>[A-Z]{3})\s+"
    r"(?P<amount_original>[\d,]+\.\d{2})\s+"
    r"(?P<amount_aed>[\d,]+\.\d{2})$"
)

_STATEMENT_DATE_RE = re.compile(
    r"\b(?:[A-Z][A-Z\s]+CARD)\s+(\d{2}-\d{2}-\d{4})\s+(\d{2}-\d{2}-\d{4})\b"
)

_SUPP_CARD_RE = re.compile(r"Supplementary Card\s*:\s*(.+)$")
_STATEMENT_REF_RE = re.compile(
    r"\b(?:Statement\s*(?:No|Number|Reference|Ref)|Ref(?:erence)?)\b\s*[:#-]?\s*([A-Z0-9\-/]*\d[A-Z0-9\-/]{5,})\b",
    re.IGNORECASE,
)


def _extract_country_code(description: str) -> str | None:
    tokens = description.split()
    if not tokens:
        return None
    maybe = tokens[-1]
    if len(maybe) == 3 and maybe.isalpha() and maybe.upper() == maybe:
        return maybe
    return None


def _extract_holder_from_line(line: str) -> str | None:
    mr_match = re.search(r"\b(MR|MRS|MS)\s+([A-Z\s]+?)\s+Main Card Product", line)
    if mr_match:
        return f"{mr_match.group(1)} {mr_match.group(2).strip()}"

    if line.replace(" ", "").isalpha() and line.upper() == line and len(line.split()) >= 2:
        return line.strip()

    return None


def _extract_statement_reference(lines: list[str]) -> str | None:
    for line in lines:
        match = _STATEMENT_REF_RE.search(line)
        if match:
            return match.group(1).strip()
    return None


def parse_fab_statement(pdf_path: str | Path) -> StatementParseResult:
    path = Path(pdf_path)
    lines: list[str] = []

    with pdfplumber.open(str(path)) as pdf:
        for page in pdf.pages:
            page_lines = [ln.strip() for ln in (page.extract_text() or "").splitlines() if ln.strip()]
            lines.extend(page_lines)

    statement_date: date | None = None
    due_date: date | None = None
    main_holder: str | None = None
    main_last4: str | None = None
    current_last4: str | None = None
    current_holder: str | None = None
    current_card_type: str | None = None

    holder_by_last4: dict[str, str] = {}
    card_type_by_last4: dict[str, str] = {}

    transactions: list[TransactionRecord] = []
    warnings: list[str] = []

    for idx, line in enumerate(lines):
        holder = _extract_holder_from_line(line)
        if holder and main_holder is None:
            main_holder = holder

        statement_match = _STATEMENT_DATE_RE.search(line)
        if statement_match and statement_date is None:
            statement_date = parse_date(statement_match.group(1), "%d-%m-%Y")
            due_date = parse_date(statement_match.group(2), "%d-%m-%Y")
            card_type_guess = line.split(statement_match.group(1))[0].strip()
            if card_type_guess:
                current_card_type = card_type_guess

        supp_match = _SUPP_CARD_RE.search(line)
        if supp_match:
            remainder = supp_match.group(1)
            supp_last4 = extract_last4_masked(remainder)
            if supp_last4:
                current_last4 = supp_last4
                if idx + 1 < len(lines):
                    supp_holder = _extract_holder_from_line(lines[idx + 1])
                    if supp_holder:
                        current_holder = supp_holder
                        holder_by_last4[supp_last4] = supp_holder
                card_type = remainder.split(supp_last4)[-1].strip()
                if card_type:
                    card_type_by_last4[supp_last4] = card_type
            continue

        masked_last4 = extract_last4_masked(line)
        if masked_last4:
            if main_last4 is None:
                main_last4 = masked_last4
                current_last4 = masked_last4
                if main_holder:
                    holder_by_last4[masked_last4] = main_holder
                if current_card_type:
                    card_type_by_last4[masked_last4] = current_card_type

            if current_last4 is None:
                current_last4 = masked_last4

        row_match = _ROW_RE.match(line)
        if not row_match:
            continue

        transaction_date = parse_date(row_match.group("txn_date"), "%d-%m-%Y")
        posting_date = parse_date(row_match.group("posting_date"), "%d-%m-%Y")
        description = row_match.group("description").strip()
        currency = row_match.group("currency")
        amount_original = parse_amount(row_match.group("amount_original"))
        amount_aed = parse_amount(row_match.group("amount_aed"))

        merchant_norm = merchant_normalize(description)
        kind = classify_transaction_kind(merchant_norm, amount_aed)
        if kind in {"payment", "refund"} and amount_aed > 0:
            amount_aed = -amount_aed
            amount_original = -amount_original

        card_last4 = current_last4 or main_last4 or "0000"
        card_holder = holder_by_last4.get(card_last4, main_holder)
        card_type = card_type_by_last4.get(card_last4, current_card_type)

        statement_month = (
            statement_month_from_date(statement_date)
            if statement_date is not None
            else statement_month_from_date(posting_date)
        )

        fingerprint = fingerprint_for(
            BANK_NAME,
            card_last4,
            posting_date,
            amount_aed,
            merchant_norm,
        )

        transactions.append(
            TransactionRecord(
                bank_name=BANK_NAME,
                card_last4=card_last4,
                card_holder=card_holder,
                card_type=card_type,
                statement_month=statement_month,
                transaction_date=transaction_date,
                posting_date=posting_date,
                merchant_raw=description,
                merchant_normalized=merchant_norm,
                country_code=_extract_country_code(description),
                amount_original=amount_original,
                currency_original=currency,
                amount_aed=amount_aed,
                fx_rate_to_aed=(amount_aed / amount_original) if amount_original else None,
                transaction_kind=kind,
                source_pdf=str(path),
                fingerprint=fingerprint,
            )
        )

    if not transactions:
        warnings.append("No FAB transaction rows matched expected pattern")

    if statement_date is None:
        warnings.append("Statement date not found; statement_month derived from posting dates")
        if transactions:
            fallback_month = statement_month_from_date(max(t.posting_date for t in transactions))
            for tx in transactions:
                tx.statement_month = fallback_month
    else:
        if due_date is not None:
            warnings.append(f"Detected due date {due_date.isoformat()}")

    result = StatementParseResult(
        bank_code=BANK_CODE,
        bank_name=BANK_NAME,
        source_pdf=path,
        statement_month=transactions[0].statement_month if transactions else "1970-01",
        transactions=transactions,
        warnings=warnings,
        metadata={
            "main_last4": main_last4,
            "main_holder": main_holder,
            "statement_date": statement_date.isoformat() if statement_date else None,
            "statement_period_end": statement_date.isoformat() if statement_date else None,
            "due_date": due_date.isoformat() if due_date else None,
            "statement_reference": _extract_statement_reference(lines),
        },
    )
    return result
