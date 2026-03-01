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

BANK_CODE = "ENBD"
BANK_NAME = "Emirates National Bank of Dubai"

_ROW_RE = re.compile(
    r"^(?P<txn_date>\d{2}/\d{2}/\d{4})\s+"
    r"(?P<posting_date>\d{2}/\d{2}/\d{4})\s+"
    r"(?P<description>.+?)\s+"
    r"(?P<amount_aed>[\d,]+\.\d{2})(?P<amount_suffix>\s*(?:CR|DR))?$",
    re.IGNORECASE,
)

_STATEMENT_PERIOD_RE = re.compile(
    r"Statement Period:\s*(\d{2}-[A-Za-z]{3}-\d{2})\s+to\s+(\d{2}-[A-Za-z]{3}-\d{2})"
)
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


def _extract_statement_reference(lines: list[str]) -> str | None:
    for line in lines:
        match = _STATEMENT_REF_RE.search(line)
        if match:
            return match.group(1).strip()
    return None


def _extract_lines(path: Path, pdf_password: str | None) -> list[str]:
    """Extract all text lines from the PDF.

    Tries without a password first (scraper / manual uploads are unencrypted).
    If that raises — indicating an email-sourced encrypted PDF — retries with
    the supplied pdf_password.
    """

    def _read(password: str | None = None) -> list[str]:
        kwargs: dict = {"password": password} if password else {}
        with pdfplumber.open(str(path), **kwargs) as pdf:
            result: list[str] = []
            for page in pdf.pages:
                result.extend(
                    ln.strip()
                    for ln in (page.extract_text() or "").splitlines()
                    if ln.strip()
                )
            return result

    try:
        return _read()
    except Exception:  # noqa: BLE001
        if not pdf_password:
            raise ParserError(
                "PDF_DECRYPT_FAILED",
                "ENBD statement PDF is encrypted. Set ENBD_PDF_PASSWORD in runtime settings.",
            )
        try:
            return _read(pdf_password)
        except Exception as exc:
            raise ParserError(
                "PDF_DECRYPT_FAILED",
                "Unable to decrypt ENBD statement PDF. Verify ENBD_PDF_PASSWORD.",
            ) from exc


def parse_enbd_statement(pdf_path: str | Path, pdf_password: str | None = None) -> StatementParseResult:
    path = Path(pdf_path)
    lines = _extract_lines(path, pdf_password)

    card_last4 = "0000"
    card_holder: str | None = None
    card_type: str | None = None
    statement_month: str | None = None
    period_start = None
    period_end = None

    warnings: list[str] = []
    transactions: list[TransactionRecord] = []

    for line in lines:
        if line.startswith("Card Number:"):
            possible_last4 = extract_last4_masked(line)
            if possible_last4:
                card_last4 = possible_last4
            continue

        if " For queries" in line and card_holder is None:
            name_candidate = line.split(" For queries", maxsplit=1)[0].strip()
            if name_candidate and name_candidate.upper() == name_candidate:
                card_holder = name_candidate

        if "Card Type:" in line and card_type is None:
            card_type = line.split("Card Type:", maxsplit=1)[-1].strip()

        period_match = _STATEMENT_PERIOD_RE.search(line)
        if period_match:
            period_start = parse_date(period_match.group(1), "%d-%b-%y")
            period_end = parse_date(period_match.group(2), "%d-%b-%y")
            statement_month = statement_month_from_date(period_end)

        row_match = _ROW_RE.match(line)
        if not row_match:
            continue

        txn_date = parse_date(row_match.group("txn_date"), "%d/%m/%Y")
        posting_date = parse_date(row_match.group("posting_date"), "%d/%m/%Y")
        description = row_match.group("description").strip()
        amount_aed = parse_amount(row_match.group("amount_aed"))
        amount_suffix = (row_match.group("amount_suffix") or "").strip().upper()
        if amount_suffix == "CR" and amount_aed > 0:
            amount_aed = -amount_aed

        merchant_norm = merchant_normalize(description)
        kind = classify_transaction_kind(merchant_norm, amount_aed)
        if kind == "refund" and amount_aed > 0:
            amount_aed = -amount_aed

        tx_statement_month = statement_month or statement_month_from_date(posting_date)
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
                statement_month=tx_statement_month,
                transaction_date=txn_date,
                posting_date=posting_date,
                merchant_raw=description,
                merchant_normalized=merchant_norm,
                country_code=_extract_country_code(description),
                amount_original=amount_aed,
                currency_original="AED",
                amount_aed=amount_aed,
                fx_rate_to_aed=1.0,
                transaction_kind=kind,
                source_pdf=str(path),
                fingerprint=fingerprint,
            )
        )

    if not transactions:
        warnings.append("No ENBD transaction rows matched expected pattern")

    if statement_month is None and transactions:
        fallback_month = statement_month_from_date(max(t.posting_date for t in transactions))
        for tx in transactions:
            tx.statement_month = fallback_month
        statement_month = fallback_month
        warnings.append("Statement period not found; using max posting month")

    return StatementParseResult(
        bank_code=BANK_CODE,
        bank_name=BANK_NAME,
        source_pdf=path,
        statement_month=statement_month or "1970-01",
        transactions=transactions,
        warnings=warnings,
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
