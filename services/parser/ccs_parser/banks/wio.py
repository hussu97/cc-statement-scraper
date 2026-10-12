"""Wio Bank "Credit Statement" (Wio Personal credit card), first real samples Jun–Sep 2026.

Page 1 carries the header and the "Account summary"; every page then lists rows as

    08/06/2026 P877005080 Noon ****2010 -47.26

one date, a reference, the description, the card (absent on payments) and a signed AED
amount: negative is a charge, positive is a credit. Wio Personal is a credit card only (no
debit card); "debit" below is the ledger direction of a charge. A foreign purchase is followed by
"Rate: 3.70 (AED/USD)" and a separate "Foreign Exchange Fee" row with the same reference.
The foreign amount itself is never printed and the rate has two decimals (EGP shows 0.07),
so the row stays an AED line. Rows like "ENBD payment" or "EIB AZ payment" (no card) are
the credit card's "pay other credit cards" feature: Wio pays another bank's card from its
credit line, a charge that moves a balance, not spend.
Totals come from ``ccs_parser.totals._extract_wio``.
"""

from __future__ import annotations

import re
from collections import Counter
from pathlib import Path

import pdfplumber

from ccs_parser.domain.parsing.models import StatementParseResult, TransactionRecord
from ccs_parser.domain.parsing.utils import (
    classify_transaction_kind,
    fingerprint_for,
    merchant_normalize,
    parse_amount,
    parse_date,
    statement_month_from_date,
)

BANK_CODE = "WIO"
BANK_NAME = "Wio Bank"

_DATE_FMT = "%d/%m/%Y"
_ROW_RE = re.compile(
    r"^(?P<date>\d{2}/\d{2}/\d{4})\s+"
    r"(?P<ref>P\d+)\s+"
    r"(?P<description>.+?)"
    r"(?:\s+\*{4}(?P<last4>\d{4}))?\s+"
    r"(?P<sign>[+-])(?P<amount>[\d,]+\.\d{2})$"
)
_PERIOD_RE = re.compile(r"\bFROM\s+(?P<start>\d{2}/\d{2}/\d{4})\s+TO\s+(?P<end>\d{2}/\d{2}/\d{4})\b")
_DUE_LABEL = "PAYMENT DUE DATE"
# The holder's name wraps, and the Arabic labels (presentation forms) sit beside it.
_NAME_RE = re.compile(r"^(?P<name>[A-Za-z][A-Za-z .'-]*?)\s*(?:\d{2}/\d{2}/\d{4}\b.*)?$")
_BALANCE_PAYMENT_RE = re.compile(r"\bPAYMENT$")


def _ascii(line: str) -> str:
    return re.sub(r"\s+", " ", "".join(ch for ch in line if ord(ch) < 128)).strip()


def _card_holder(lines: list[str]) -> str | None:
    """The name printed left of the "PAYMENT DUE DATE" label, wrapped over the next lines."""
    for idx, raw in enumerate(lines[:40]):
        line = _ascii(raw)
        if _DUE_LABEL not in line.upper():
            continue
        parts = [line[: line.upper().index(_DUE_LABEL)].strip()]
        for nxt in lines[idx + 1 : idx + 4]:
            text = _ascii(nxt)
            match = _NAME_RE.match(text)
            if not text or not match or not match["name"].strip():
                break
            parts.append(match["name"].strip())
            if match["name"].strip() != text:  # the due date / amounts row ends the name
                break
        name = " ".join(p for p in parts if p)
        return name or None
    return None


def _kind(description: str, amount_aed: float, last4: str | None) -> str:
    merchant = merchant_normalize(description)
    if amount_aed > 0 and last4 is None and _BALANCE_PAYMENT_RE.search(merchant):
        return "payment"
    kind = classify_transaction_kind(merchant, amount_aed)
    # The shared rule calls every unlabelled credit a payment; on Wio only the bank's own
    # "Credit Repayment" rows are, and a merchant credit is a refund.
    if kind == "payment" and amount_aed < 0 and "PAYMENT" not in merchant:
        return "refund"
    return kind


def parse_wio_statement(pdf_path: str | Path, pdf_password: str | None = None) -> StatementParseResult:
    path = Path(pdf_path)
    open_kwargs: dict = {"password": pdf_password} if pdf_password else {}
    with pdfplumber.open(str(path), **open_kwargs) as pdf:
        lines: list[str] = []
        for page in pdf.pages:
            lines.extend(ln.strip() for ln in (page.extract_text() or "").splitlines() if ln.strip())

    period_start = period_end = None
    for line in lines:
        if (match := _PERIOD_RE.search(_ascii(line))) is not None:
            period_start = parse_date(match["start"], _DATE_FMT)
            period_end = parse_date(match["end"], _DATE_FMT)
            break

    warnings: list[str] = []
    rows = [m for line in lines if (m := _ROW_RE.match(_ascii(line))) is not None]

    card_counts = Counter(m["last4"] for m in rows if m["last4"])
    primary_last4 = card_counts.most_common(1)[0][0] if card_counts else None
    card_holder = _card_holder(lines)
    statement_month = statement_month_from_date(period_end) if period_end else None

    transactions: list[TransactionRecord] = []
    for match in rows:
        posting_date = parse_date(match["date"], _DATE_FMT)
        description = match["description"].strip()
        amount_aed = parse_amount(match["amount"])
        if match["sign"] == "+":
            amount_aed = -amount_aed  # a credit; the ledger's debits are positive
        last4 = match["last4"] or primary_last4 or "0000"
        merchant_norm = merchant_normalize(description)
        transactions.append(
            TransactionRecord(
                bank_name=BANK_NAME,
                card_last4=last4,
                card_holder=card_holder,
                card_type=None,
                statement_month=statement_month or statement_month_from_date(posting_date),
                transaction_date=posting_date,
                posting_date=posting_date,
                merchant_raw=description,
                merchant_normalized=merchant_norm,
                country_code=None,
                amount_original=amount_aed,
                currency_original="AED",
                amount_aed=amount_aed,
                fx_rate_to_aed=1.0,
                transaction_kind=_kind(description, amount_aed, match["last4"]),
                source_pdf=str(path),
                fingerprint=fingerprint_for(BANK_NAME, last4, posting_date, amount_aed, merchant_norm),
            )
        )

    if period_end is None:
        warnings.append("WIO: statement period not found")
        if transactions:
            period_end = max(t.posting_date for t in transactions)
            statement_month = statement_month_from_date(period_end)
            for tx in transactions:
                tx.statement_month = statement_month
    if not transactions:
        warnings.append("WIO: no transaction rows this period")

    return StatementParseResult(
        bank_code=BANK_CODE,
        bank_name=BANK_NAME,
        source_pdf=path,
        statement_month=statement_month or "1970-01",
        transactions=transactions,
        warnings=warnings,
        metadata={
            "card_last4": primary_last4,
            "card_holder": card_holder,
            "card_type": None,
            "statement_period_start": period_start.isoformat() if period_start else None,
            "statement_period_end": period_end.isoformat() if period_end else None,
            "statement_date": period_end.isoformat() if period_end else None,
            "statement_reference": None,
        },
    )
