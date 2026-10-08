from __future__ import annotations

import hashlib
import re
from datetime import date, datetime


_FEE_WORD_RE = re.compile(r"\bFEES?\b|\bCHARGES?\b")


def parse_amount(raw: str) -> float:
    return float(raw.replace(",", "").strip())


def parse_date(raw: str, fmt: str) -> date:
    return datetime.strptime(raw.strip(), fmt).date()


def statement_month_from_date(value: date) -> str:
    return value.strftime("%Y-%m")


def merchant_normalize(raw: str) -> str:
    value = raw.upper()
    value = re.sub(r"\s+", " ", value)
    value = value.strip(" .,-")
    return value


def extract_last4_masked(line: str) -> str | None:
    patterns = [
        r"(?:\d{4}\s+)?\d{2}[X\*]{2}\s+[X\*]{4}\s+(\d{4})",
        r"\b\d{4}\s+[X\*]{4}\s+[X\*]{4}\s+(\d{4})\b",
    ]
    for pattern in patterns:
        match = re.search(pattern, line)
        if match:
            return match.group(1)
    return None


def classify_transaction_kind(merchant_normalized: str, amount_aed: float | None) -> str:
    merchant = merchant_normalized.upper()
    if "PAYMENT RECEIVED" in merchant or merchant.endswith(" THANK YOU"):
        return "payment"
    if "REFUND" in merchant or "REVERSAL" in merchant:
        return "refund"
    if "REWARDS REDEMPTION" in merchant and "CASHBACK" in merchant:
        return "refund"
    # Whole words only: legacy substring matching classified "COFFEE" and
    # "RECHARGE" as fees.
    if _FEE_WORD_RE.search(merchant):
        return "fee"
    if "CASH ADV" in merchant:
        return "cash_advance"
    if amount_aed is not None and amount_aed < 0:
        return "payment"
    return "purchase"


def fingerprint_for(
    bank_name: str,
    card_last4: str,
    posting_date: date,
    amount_aed: float | None,
    merchant_normalized: str,
) -> str:
    seed = "|".join(
        [
            bank_name,
            card_last4,
            posting_date.isoformat(),
            "" if amount_aed is None else f"{amount_aed:.2f}",
            merchant_normalized,
        ]
    )
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()
