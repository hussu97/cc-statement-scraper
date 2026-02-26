from __future__ import annotations

import re
from pathlib import Path

import pdfplumber

from ccs_platform.domain.parsing.models import ParserError, StatementParseResult, TransactionRecord
from ccs_platform.domain.parsing.utils import (
    classify_transaction_kind,
    extract_last4_masked,
    fingerprint_for,
    merchant_normalize,
    parse_amount,
    parse_date,
    statement_month_from_date,
)


BANK_CODE = "SIB"
BANK_NAME = "Sharjah Islamic Bank"

_ROW_RE = re.compile(
    r"^(?P<txn_date>\d{2}[/-]\d{2}[/-]\d{4})\s+"
    r"(?P<posting_date>\d{2}[/-]\d{2}[/-]\d{4})\s+"
    r"(?P<description>.+?)\s+"
    r"(?P<amount>[\d,]+\.\d{2})\s*(?P<drcr>DR|CR)?$",
    re.IGNORECASE,
)
_PERIOD_RE = re.compile(
    r"(?:statement\s*period|period)\s*[:\-]?\s*"
    r"(\d{2}[/-]\d{2}[/-]\d{4})\s*(?:to|-)\s*(\d{2}[/-]\d{2}[/-]\d{4})",
    re.IGNORECASE,
)
_STATEMENT_REF_RE = re.compile(
    r"(?:statement\s*(?:no|number|reference|ref)|ref)\s*[:#-]?\s*([A-Z0-9\-/]{6,})",
    re.IGNORECASE,
)


def _extract_statement_reference(lines: list[str]) -> str | None:
    for line in lines:
        match = _STATEMENT_REF_RE.search(line)
        if match:
            return match.group(1).strip()
    return None


def _parse_date_any(raw: str):
    token = raw.strip()
    for fmt in ("%d/%m/%Y", "%d-%m-%Y"):
        try:
            return parse_date(token, fmt)
        except ValueError:
            continue
    raise ValueError(f"Unsupported date format: {raw!r}")


def parse_sib_statement(pdf_path: str | Path, pdf_password: str) -> StatementParseResult:
    path = Path(pdf_path)
    if not pdf_password:
        raise ParserError("PDF_DECRYPT_FAILED", "Missing SIB PDF password")

    try:
        with pdfplumber.open(str(path), password=pdf_password) as pdf:
            lines: list[str] = []
            for page in pdf.pages:
                page_lines = [ln.strip() for ln in (page.extract_text() or "").splitlines() if ln.strip()]
                lines.extend(page_lines)
    except Exception as exc:  # noqa: BLE001
        raise ParserError(
            "PDF_DECRYPT_FAILED",
            "Unable to open/decrypt SIB statement PDF. Verify SIB_PDF_PASSWORD.",
        ) from exc

    card_last4 = "0000"
    card_holder: str | None = None
    card_type: str | None = None
    statement_month: str | None = None
    period_start = None
    period_end = None

    transactions: list[TransactionRecord] = []

    for line in lines:
        possible_last4 = extract_last4_masked(line)
        if possible_last4:
            card_last4 = possible_last4

        period_match = _PERIOD_RE.search(line)
        if period_match:
            period_start = _parse_date_any(period_match.group(1))
            period_end = _parse_date_any(period_match.group(2))
            statement_month = statement_month_from_date(period_end)

        row_match = _ROW_RE.match(line)
        if not row_match:
            continue

        txn_date = _parse_date_any(row_match.group("txn_date"))
        posting_date = _parse_date_any(row_match.group("posting_date"))
        description = row_match.group("description").strip()
        amount = parse_amount(row_match.group("amount"))
        drcr = (row_match.group("drcr") or "").upper()
        if drcr == "CR":
            amount = -amount

        merchant_norm = merchant_normalize(description)
        kind = classify_transaction_kind(merchant_norm, amount)
        if kind == "refund" and amount > 0:
            amount = -amount

        tx_month = statement_month or statement_month_from_date(posting_date)
        transactions.append(
            TransactionRecord(
                bank_name=BANK_NAME,
                card_last4=card_last4,
                card_holder=card_holder,
                card_type=card_type,
                statement_month=tx_month,
                transaction_date=txn_date,
                posting_date=posting_date,
                merchant_raw=description,
                merchant_normalized=merchant_norm,
                country_code=None,
                amount_original=amount,
                currency_original="AED",
                amount_aed=amount,
                fx_rate_to_aed=1.0,
                transaction_kind=kind,
                source_pdf=str(path),
                fingerprint=fingerprint_for(BANK_NAME, card_last4, posting_date, amount, merchant_norm),
            )
        )

    if not transactions:
        raise ParserError(
            "UNSUPPORTED_LAYOUT",
            "SIB parser could not match transaction rows. Statement layout may have changed.",
        )

    if statement_month is None:
        statement_month = statement_month_from_date(max(tx.posting_date for tx in transactions))
        for tx in transactions:
            tx.statement_month = statement_month

    return StatementParseResult(
        bank_code=BANK_CODE,
        bank_name=BANK_NAME,
        source_pdf=path,
        statement_month=statement_month,
        transactions=transactions,
        warnings=[],
        metadata={
            "card_last4": card_last4,
            "card_holder": card_holder,
            "card_type": card_type,
            "statement_period_start": period_start.isoformat() if period_start else None,
            "statement_period_end": period_end.isoformat() if period_end else None,
            "statement_date": period_end.isoformat() if period_end else None,
            "statement_reference": _extract_statement_reference(lines),
        },
    )
