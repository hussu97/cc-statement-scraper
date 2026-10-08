"""Map legacy transaction kinds to the parse-v1 contract kind set."""

from __future__ import annotations

import re

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
