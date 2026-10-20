"""Map legacy transaction kinds to the parse-v1 contract kind set."""

from __future__ import annotations

import re
from collections.abc import Sequence
from datetime import date
from typing import Protocol

CONTRACT_KINDS = frozenset({"purchase", "refund", "payment", "fee", "interest", "cash_advance", "adjustment"})

# Interest / Islamic-finance profit charges. MURABAHA PROFIT is SIB's interest line.
_INTEREST_RE = re.compile(r"\bINTEREST\b|PROFIT CHARGE|FINANCE CHARGE|MURABAHA PROFIT")


def map_kind(legacy_kind: str, description: str, direction: str) -> str:
    """Return the contract kind for a parsed line.

    Legacy kinds are purchase/refund/payment/fee/cash_advance and are kept as-is,
    except that *debit* fee/purchase lines describing interest or profit charges
    become ``interest``. Credits (e.g. interest reversals) and VAT lines keep
    their legacy kind.
    """
    kind = (legacy_kind or "").strip().lower()
    text = (description or "").upper()
    if (
        direction == "debit"
        and kind in {"fee", "purchase"}
        and not text.startswith("VAT ")
        and _INTEREST_RE.search(text)
    ):
        return "interest"
    if kind in CONTRACT_KINDS:
        return kind
    return "adjustment"


# The bank's fee for a cash advance. Its VAT line ("VAT ON CASH ADVANCE FEE") is not the anchor.
_CASH_ADVANCE_FEE_RE = re.compile(r"^CASH ADV(?:ANCE)? FEE\b")
# Lines a bank prints between a withdrawal and its fee (FAB: "VAT ON SERVICE CHARGES").
_BETWEEN_KINDS = frozenset({"fee", "interest"})
_MAX_LOOKBACK = 3


class _KindLine(Protocol):
    transaction_date: date
    merchant_normalized: str
    direction: str
    card_last4: str | None


def pair_cash_advances(lines: Sequence[_KindLine], kinds: Sequence[str]) -> list[str]:
    """Return ``kinds`` with each withdrawal that a CASH ADVANCE FEE follows marked ``cash_advance``.

    An ATM abroad is printed as the ATM owner's name ("DTBKEN NAIROBI KEN"), so the line itself
    looks like a purchase; the bank's fee right after it (same card, same date, fee/VAT lines
    in between) is what says it was cash. ``lines`` are in statement order.
    """
    out = list(kinds)
    for i, fee in enumerate(lines):
        if fee.direction != "debit" or not _CASH_ADVANCE_FEE_RE.match((fee.merchant_normalized or "").upper()):
            continue
        for j in range(i - 1, max(i - 1 - _MAX_LOOKBACK, -1), -1):
            prev = lines[j]
            if out[j] in _BETWEEN_KINDS:
                continue
            if (
                out[j] == "purchase"
                and prev.direction == "debit"
                and prev.transaction_date == fee.transaction_date
                and prev.card_last4 == fee.card_last4
            ):
                out[j] = "cash_advance"
            break
    return out
