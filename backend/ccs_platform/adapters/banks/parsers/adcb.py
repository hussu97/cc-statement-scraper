from __future__ import annotations

import re
from datetime import date
from pathlib import Path

import pdfplumber

from ccs_platform.domain.parsing.models import ParserError, StatementParseResult, TransactionRecord
from ccs_platform.domain.parsing.utils import (
    classify_transaction_kind,
    fingerprint_for,
    merchant_normalize,
    parse_amount,
    parse_date,
    statement_month_from_date,
)

BANK_CODE = "ADCB"
BANK_NAME = "Abu Dhabi Central Bank"

_FOREIGN_ROW_RE = re.compile(
    r"^(?P<txn_date>\d{2}/\d{2}/\d{4})\s+"
    r"(?P<description>.+?)\s+"
    r"(?P<country_code>[A-Z]{3})\s+"
    r"(?P<amount_original>[\d,]+\.\d{2})\s+"
    r"(?P<currency>[A-Z]{3})\s+"
    r"(?P<amount_aed>[\d,]+\.\d{2})$"
)

_PAYMENT_ROW_RE = re.compile(
    r"^(?P<txn_date>\d{2}/\d{2}/\d{4})\s+"
    r"(?P<description>.+?)\s+"
    r"(?P<amount_aed>[\d,]+\.\d{2})\s+CR$"
)

# Local AED debit — charged in AED with no foreign currency conversion.
# Covers both fee rows (no country code) and overseas merchants billed in AED
# (country code embedded in description, e.g. "GETYOURGUIDE DEUTSCHLA BERLIN DEU  942.32").
_LOCAL_ROW_RE = re.compile(
    r"^(?P<txn_date>\d{2}/\d{2}/\d{4})\s+"
    r"(?P<description>.+?)\s+"
    r"(?P<amount_aed>[\d,]+\.\d{2})$"
)

_FX_RE = re.compile(r"^\[1\s+(?P<currency>[A-Z]{3})=AED\s+(?P<fx>[\d.]+)\]$")

_CARD_RE = re.compile(r"Card No\s*:\s*[^\d]*(?:\d|X|\*)+(\d{4})\s*-\s*(.+)$")
_STATEMENT_REF_RE = re.compile(
    r"\b(?:Statement\s*(?:No|Number|Reference|Ref)|Ref(?:erence)?)\b\s*[:#-]?\s*([A-Z0-9\-/]*\d[A-Z0-9\-/]{5,})\b",
    re.IGNORECASE,
)

_IGNORE_PATTERNS = [
    re.compile(r"PREVIOUS BALANCE OUTSTANDING", re.IGNORECASE),
    re.compile(r"NEW BALANCE OUTSTANDING", re.IGNORECASE),
    re.compile(r"^Page\s+\d+\s+of\s+\d+$", re.IGNORECASE),
]



def _should_ignore(line: str) -> bool:
    for pattern in _IGNORE_PATTERNS:
        if pattern.search(line):
            return True
    return False


def _extract_statement_reference(lines: list[str]) -> str | None:
    for line in lines:
        match = _STATEMENT_REF_RE.search(line)
        if match:
            return match.group(1).strip()
    return None


def parse_adcb_statement(pdf_path: str | Path, pdf_password: str) -> StatementParseResult:
    path = Path(pdf_path)

    if not pdf_password:
        raise ParserError("PDF_DECRYPT_FAILED", "Missing ADCB PDF password")

    try:
        with pdfplumber.open(str(path), password=pdf_password) as pdf:
            lines: list[str] = []
            for page in pdf.pages:
                page_lines = [ln.strip() for ln in (page.extract_text() or "").splitlines() if ln.strip()]
                lines.extend(page_lines)
    except Exception as exc:  # noqa: BLE001
        raise ParserError(
            "PDF_DECRYPT_FAILED",
            "Unable to open/decrypt ADCB statement PDF. Verify ADCB_PDF_PASSWORD or ADCB_CID.",
        ) from exc

    card_last4 = "0000"
    card_holder: str | None = None
    statement_date: date | None = None

    transactions: list[TransactionRecord] = []
    warnings: list[str] = []
    last_tx_index: int | None = None

    for line in lines:
        card_match = _CARD_RE.search(line)
        if card_match:
            card_last4 = card_match.group(1)
            card_holder = card_match.group(2).strip()

        if statement_date is None:
            short_date_match = re.search(r"\b(\d{2}/\d{2}/\d{2})\b", line)
            if short_date_match:
                statement_date = parse_date(short_date_match.group(1), "%d/%m/%y")

        if _should_ignore(line):
            continue

        fx_match = _FX_RE.match(line)
        if fx_match and last_tx_index is not None:
            fx_currency = fx_match.group("currency")
            if transactions[last_tx_index].currency_original == fx_currency:
                transactions[last_tx_index].fx_rate_to_aed = float(fx_match.group("fx"))
            continue

        payment_match = _PAYMENT_ROW_RE.match(line)
        if payment_match:
            txn_date = parse_date(payment_match.group("txn_date"), "%d/%m/%Y")
            posting_date = txn_date
            description = payment_match.group("description").strip()
            amount_aed = -parse_amount(payment_match.group("amount_aed"))
            merchant_norm = merchant_normalize(description)
            statement_month = statement_month_from_date(statement_date or posting_date)
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
                    card_type="Credit Card",
                    statement_month=statement_month,
                    transaction_date=txn_date,
                    posting_date=posting_date,
                    merchant_raw=description,
                    merchant_normalized=merchant_norm,
                    country_code=None,
                    amount_original=amount_aed,
                    currency_original="AED",
                    amount_aed=amount_aed,
                    fx_rate_to_aed=1.0,
                    transaction_kind="payment",
                    source_pdf=str(path),
                    fingerprint=fingerprint,
                )
            )
            last_tx_index = len(transactions) - 1
            continue

        row_match = _FOREIGN_ROW_RE.match(line)
        if row_match:
            txn_date = parse_date(row_match.group("txn_date"), "%d/%m/%Y")
            posting_date = txn_date
            description = row_match.group("description").strip()
            country_code = row_match.group("country_code")
            amount_original = parse_amount(row_match.group("amount_original"))
            currency = row_match.group("currency")
            amount_aed = parse_amount(row_match.group("amount_aed"))

            merchant_norm = merchant_normalize(description)
            kind = classify_transaction_kind(merchant_norm, amount_aed)
            if kind == "refund" and amount_aed > 0:
                amount_aed = -amount_aed
                amount_original = -amount_original

            statement_month = statement_month_from_date(statement_date or posting_date)
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
                    card_type="Credit Card",
                    statement_month=statement_month,
                    transaction_date=txn_date,
                    posting_date=posting_date,
                    merchant_raw=description,
                    merchant_normalized=merchant_norm,
                    country_code=country_code,
                    amount_original=amount_original,
                    currency_original=currency,
                    amount_aed=amount_aed,
                    fx_rate_to_aed=(amount_aed / amount_original) if amount_original else None,
                    transaction_kind=kind,
                    source_pdf=str(path),
                    fingerprint=fingerprint,
                )
            )
            last_tx_index = len(transactions) - 1
            continue

        # Local AED debit — no foreign currency conversion (fees, or overseas
        # merchants billed directly in AED).
        local_match = _LOCAL_ROW_RE.match(line)
        if not local_match:
            continue

        txn_date = parse_date(local_match.group("txn_date"), "%d/%m/%Y")
        posting_date = txn_date
        description = local_match.group("description").strip()
        amount_aed = parse_amount(local_match.group("amount_aed"))

        merchant_norm = merchant_normalize(description)
        kind = classify_transaction_kind(merchant_norm, amount_aed)
        if kind == "refund" and amount_aed > 0:
            amount_aed = -amount_aed

        statement_month = statement_month_from_date(statement_date or posting_date)
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
                card_type="Credit Card",
                statement_month=statement_month,
                transaction_date=txn_date,
                posting_date=posting_date,
                merchant_raw=description,
                merchant_normalized=merchant_norm,
                country_code=None,
                amount_original=amount_aed,
                currency_original="AED",
                amount_aed=amount_aed,
                fx_rate_to_aed=1.0,
                transaction_kind=kind,
                source_pdf=str(path),
                fingerprint=fingerprint,
            )
        )
        last_tx_index = len(transactions) - 1

    if not transactions:
        warnings.append("No ADCB rows matched expected patterns")

    if statement_date is None and transactions:
        warnings.append("Statement date not detected; using max posting month")
        fallback_month = statement_month_from_date(max(t.posting_date for t in transactions))
        for tx in transactions:
            tx.statement_month = fallback_month

    return StatementParseResult(
        bank_code=BANK_CODE,
        bank_name=BANK_NAME,
        source_pdf=path,
        statement_month=transactions[0].statement_month if transactions else "1970-01",
        transactions=transactions,
        warnings=warnings,
        metadata={
            "card_last4": card_last4,
            "card_holder": card_holder,
            "statement_date": statement_date.isoformat() if statement_date else None,
            "statement_period_end": statement_date.isoformat() if statement_date else None,
            "statement_reference": _extract_statement_reference(lines),
        },
    )
