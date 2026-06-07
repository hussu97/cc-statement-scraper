from __future__ import annotations

import re
from datetime import date
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

# --- Transaction History format ---
# Row: "12 Mar 2026   SHJ COOPERATIVE SOCIETSHARJAH   AED -211.80"
_TH_ROW_RE = re.compile(
    r"^(?P<txn_date>\d{1,2}\s+[A-Za-z]{3}\s+\d{4})\s+"
    r"(?P<description>.+?)\s+"
    r"(?P<currency>[A-Z]{3})\s+(?P<amount>-?[\d,]+\.\d{2})$",
)
_TH_DATE_FMT = "%d %b %Y"
_ACCOUNT_NO_RE = re.compile(r"Account\s+no\.\s+(.+)", re.IGNORECASE)
_ACCOUNT_TYPE_RE = re.compile(r"Account\s+type\s+(.+)", re.IGNORECASE)
_STATEMENT_CUTOFF_DAY = 12
_TH_PAYMENT_KEYWORDS = ("CREDIT CARD PAYMENT",)
_TH_FEE_KEYWORDS = ("MURABAHA PROFIT", "FINANCE CHARGE", "SERVICE CHARGE")


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


def is_transaction_history(lines: list[str]) -> bool:
    """Return True if the PDF text looks like a SIB transaction history export."""
    for line in lines[:10]:
        if "TRANSACTION HISTORY" in line.upper():
            return True
    return False


def _statement_date_for_txn(txn_date: date) -> date:
    """Map a transaction date to its billing cycle statement date (12th of month)."""
    if txn_date.day <= _STATEMENT_CUTOFF_DAY:
        # Belongs to the statement closing on the 12th of the same month
        return date(txn_date.year, txn_date.month, _STATEMENT_CUTOFF_DAY)
    else:
        # Belongs to the statement closing on the 12th of the next month
        if txn_date.month == 12:
            return date(txn_date.year + 1, 1, _STATEMENT_CUTOFF_DAY)
        return date(txn_date.year, txn_date.month + 1, _STATEMENT_CUTOFF_DAY)


def _period_start_for_statement_date(stmt_date: date) -> date:
    """Return the 13th of the prior month (start of this billing cycle)."""
    if stmt_date.month == 1:
        prior_year = stmt_date.year - 1
        prior_month = 12
    else:
        prior_year = stmt_date.year
        prior_month = stmt_date.month - 1
    return date(prior_year, prior_month, 13)


def _sib_history_platform_amount(source_amount: float) -> float:
    """SIB history exports card spend as negative and credits as positive."""
    return -source_amount


def _classify_sib_history_kind(merchant_normalized: str, source_amount: float, platform_amount: float) -> str:
    merchant = merchant_normalized.upper()
    if source_amount > 0:
        if any(keyword in merchant for keyword in _TH_PAYMENT_KEYWORDS):
            return "payment"
        return "refund"
    if any(keyword in merchant for keyword in _TH_FEE_KEYWORDS):
        return "fee"
    return classify_transaction_kind(merchant_normalized, platform_amount)


def parse_sib_transaction_history(pdf_path: str | Path, pdf_password: str | None = None) -> list[StatementParseResult]:
    """Parse a SIB 'Transaction history' PDF and split into per-billing-cycle statements.

    Each billing cycle closes on the 12th of the month: transactions dated 13th of month M
    through 12th of month M+1 are grouped into the statement dated 12th of M+1.
    """
    path = Path(pdf_path)
    open_kwargs: dict = {}
    if pdf_password:
        open_kwargs["password"] = pdf_password

    try:
        with pdfplumber.open(str(path), **open_kwargs) as pdf:
            lines: list[str] = []
            for page in pdf.pages:
                page_lines = [ln.strip() for ln in (page.extract_text() or "").splitlines() if ln.strip()]
                lines.extend(page_lines)
    except Exception as exc:  # noqa: BLE001
        raise ParserError(
            "PDF_DECRYPT_FAILED",
            "Unable to open SIB transaction history PDF.",
        ) from exc

    # Extract header metadata from first ~15 lines
    card_holder: str | None = None
    card_last4: str | None = None
    card_type: str | None = None

    for line in lines[:15]:
        acct_match = _ACCOUNT_NO_RE.search(line)
        if acct_match:
            raw_acct = acct_match.group(1).strip()
            # Format: "5290 xxxx xxxx 6774" — last 4 digits are card last4
            digits = re.sub(r"[^0-9]", "", raw_acct)
            if len(digits) >= 4:
                card_last4 = digits[-4:]
            continue
        acct_type_match = _ACCOUNT_TYPE_RE.search(line)
        if acct_type_match:
            card_type = acct_type_match.group(1).strip()
            continue
        # Card holder is the bold name line — appears before "Date range"
        if "DATE RANGE" in line.upper() and card_holder is None and len(lines) > 1:
            # holder is the line right before the table metadata block; already captured below
            pass

    # Card holder: first non-header line that looks like a name (all words, before "Date range")
    for line in lines[:8]:
        low = line.lower()
        if any(kw in low for kw in ("transaction history", "date range", "account no", "account type", "currency", "date", "details", "amount")):
            continue
        if re.match(r"^[A-Za-z\s]+$", line) and len(line) > 4:
            card_holder = line.strip()
            break

    if not card_last4:
        card_last4 = "0000"

    # Parse all transaction rows; deduplicate by fingerprint
    all_txns: list[TransactionRecord] = []
    seen_fingerprints: set[str] = set()

    for line in lines:
        m = _TH_ROW_RE.match(line)
        if not m:
            continue

        try:
            txn_date = parse_date(m.group("txn_date"), _TH_DATE_FMT)
        except ValueError:
            continue

        description = m.group("description").strip()
        currency = m.group("currency").upper()
        try:
            amount_raw = parse_amount(m.group("amount"))
        except ValueError:
            continue

        merchant_norm = merchant_normalize(description)
        amount_platform = _sib_history_platform_amount(amount_raw)
        # For AED transactions, amount_aed is the normalized platform amount;
        # for foreign transactions, AED equivalent is not available in history PDFs.
        amount_aed = amount_platform if currency == "AED" else None

        fp = fingerprint_for(
            BANK_NAME,
            card_last4,
            txn_date,
            amount_aed if amount_aed is not None else amount_platform,
            merchant_norm,
        )
        if fp in seen_fingerprints:
            continue
        seen_fingerprints.add(fp)

        stmt_date = _statement_date_for_txn(txn_date)
        stmt_month = statement_month_from_date(stmt_date)
        kind = _classify_sib_history_kind(merchant_norm, amount_raw, amount_platform)

        all_txns.append(
            TransactionRecord(
                bank_name=BANK_NAME,
                card_last4=card_last4,
                card_holder=card_holder,
                card_type=card_type,
                statement_month=stmt_month,
                transaction_date=txn_date,
                posting_date=txn_date,
                merchant_raw=description,
                merchant_normalized=merchant_norm,
                country_code=None,
                amount_original=amount_platform,
                currency_original=currency,
                amount_aed=amount_aed,
                fx_rate_to_aed=1.0 if currency == "AED" else None,
                transaction_kind=kind,
                source_pdf=str(path),
                fingerprint=fp,
            )
        )

    if not all_txns:
        raise ParserError(
            "UNSUPPORTED_LAYOUT",
            "SIB transaction history parser could not match any transaction rows.",
        )

    # Group transactions by statement date bucket
    buckets: dict[date, list[TransactionRecord]] = {}
    for txn in all_txns:
        stmt_date = _statement_date_for_txn(txn.transaction_date)
        buckets.setdefault(stmt_date, []).append(txn)

    results: list[StatementParseResult] = []
    for stmt_date in sorted(buckets):
        txns = buckets[stmt_date]
        stmt_month = statement_month_from_date(stmt_date)
        period_start = _period_start_for_statement_date(stmt_date)

        results.append(
            StatementParseResult(
                bank_code=BANK_CODE,
                bank_name=BANK_NAME,
                source_pdf=path,
                statement_month=stmt_month,
                transactions=txns,
                warnings=[],
                metadata={
                    "card_last4": card_last4,
                    "card_holder": card_holder,
                    "card_type": card_type,
                    "statement_date": stmt_date.isoformat(),
                    "statement_period_start": period_start.isoformat(),
                    "statement_period_end": stmt_date.isoformat(),
                    "statement_reference": None,
                    "pdf_type": "transaction_history",
                },
            )
        )

    return results
