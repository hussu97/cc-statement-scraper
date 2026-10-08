"""Best-effort extraction of statement summary totals.

This is new functionality (the legacy backend never extracted totals). It is
deliberately conservative: a value is only returned when the statement text
contains the bank's summary block in the exact layout observed on real PDFs.
Everything else is ``None``. ``extract_totals`` never raises; failures become
warnings.

Verified layouts (against real statements):
  * FAB  -- "Current Balance / Minimum Payment Due" header row, the
            "Previous Balance + Purchases ... Total Payment Due" summary row and
            the "Total Credit Limit / Available Credit Limit" row.
  * ENBD -- "Credit Limit / Available Credit Limit / Statement Date / Payment
            Due Date / Minimum Payment Due" row and the "STATEMENT SUMMARY" row.
Unverified (no decryptable samples were available):
  * EIB  -- same statement template family as ENBD; the ENBD rules are applied.
  * ADCB -- "PREVIOUS/NEW BALANCE OUTSTANDING <amount>" lines.
  * MASHREQ -- not implemented (all null).
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

from ccs_parser.limits import max_pages

logger = logging.getLogger(__name__)

TOTAL_KEYS: tuple[str, ...] = (
    "opening_balance",
    "closing_balance",
    "total_debits",
    "total_credits",
    "min_due",
    "credit_limit",
)

# Amount tokens as printed in summary blocks: "1,234.56", "-.55", "-1,579.06", "20000".
_AMOUNT_TOKEN_RE = re.compile(r"^-?(?:\d{1,3}(?:,\d{3})+|\d+)?(?:\.\d{2})?$")
_DECIMAL_AMOUNT_RE = r"-?(?:\d{1,3}(?:,\d{3})+|\d+)?\.\d{2}"
_LOOKAHEAD_LINES = 4


@dataclass
class TotalsResult:
    values: dict[str, Decimal | None] = field(default_factory=lambda: dict.fromkeys(TOTAL_KEYS))
    due_date: date | None = None
    warnings: list[str] = field(default_factory=list)

    @property
    def found_any(self) -> bool:
        return any(v is not None for v in self.values.values())


def _to_decimal(token: str) -> Decimal | None:
    """Parse an amount token; a trailing ``CR`` (credit balance) makes it negative."""
    token = token.strip()
    credit = token.upper().endswith("CR")
    if credit:
        token = token[:-2].strip()
    value = _plain_decimal(token)
    if value is not None and credit:
        value = -abs(value)
    return value


def _plain_decimal(token: str) -> Decimal | None:
    if not token or not _AMOUNT_TOKEN_RE.match(token) or not any(ch.isdigit() for ch in token):
        return None
    try:
        return Decimal(token.replace(",", ""))
    except InvalidOperation:
        return None


def _amount_row(line: str) -> list[Decimal] | None:
    """Return the amounts if *every* whitespace token on the line is an amount."""
    tokens = line.split()
    if not tokens:
        return None
    values = [_to_decimal(tok) for tok in tokens]
    if any(v is None for v in values):
        return None
    return values  # type: ignore[return-value]


def _following(lines: list[str], idx: int) -> list[str]:
    return lines[idx + 1 : idx + 1 + _LOOKAHEAD_LINES]


def _parse_dmy(raw: str) -> date | None:
    for fmt in ("%d/%m/%Y", "%d-%m-%Y"):
        try:
            return datetime.strptime(raw, fmt).date()
        except ValueError:
            continue
    return None


# --------------------------------------------------------------------------- FAB

_FAB_BALANCE_ROW_RE = re.compile(
    rf"(?:\*{{2,}}|X{{2,}}).*?\d{{4}}\s+(?P<balance>{_DECIMAL_AMOUNT_RE})(?P<cr>\s*CR)?\s+(?P<min>{_DECIMAL_AMOUNT_RE})$",
    re.IGNORECASE,
)


def _extract_fab(lines: list[str], result: TotalsResult) -> None:
    v = result.values
    for idx, line in enumerate(lines):
        upper = line.upper()
        if "CURRENT BALANCE" in upper and "MINIMUM PAYMENT DUE" in upper and v["closing_balance"] is None:
            for nxt in _following(lines, idx):
                m = _FAB_BALANCE_ROW_RE.search(nxt)
                if m:
                    balance = _to_decimal(m.group("balance"))
                    if balance is not None and m.group("cr"):
                        balance = -abs(balance)
                    v["closing_balance"] = balance
                    v["min_due"] = _to_decimal(m.group("min"))
                    break
        elif upper.startswith("PREVIOUS BALANCE") and "PAYMENTS/CREDITS" in upper and v["opening_balance"] is None:
            for nxt in _following(lines, idx):
                row = _amount_row(nxt)
                if row and len(row) == 6:
                    prev, purchases, cash, finance, credits, total_due = row
                    v["opening_balance"] = prev
                    v["total_debits"] = purchases + cash + finance
                    v["total_credits"] = credits
                    if v["closing_balance"] is None:
                        v["closing_balance"] = total_due
                    break
        elif "TOTAL CREDIT LIMIT" in upper and "AVAILABLE CREDIT LIMIT" in upper and v["credit_limit"] is None:
            for nxt in _following(lines, idx):
                row = _amount_row(nxt)
                if row and len(row) == 2:
                    v["credit_limit"] = row[0]
                    break


# ---------------------------------------------------------------- ENBD / EIB

_ENBD_LIMIT_ROW_RE = re.compile(
    r"^(?P<limit>(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{2})?)\s+"
    rf"(?P<available>{_DECIMAL_AMOUNT_RE})\s+"
    r"(?P<statement_date>\d{2}/\d{2}/\d{4})\s+"
    r"(?P<due_date>\d{2}/\d{2}/\d{4})\s+"
    rf"(?P<min>{_DECIMAL_AMOUNT_RE})$"
)


def _extract_enbd(lines: list[str], result: TotalsResult) -> None:
    v = result.values
    for idx, line in enumerate(lines):
        upper = line.upper()
        if "CREDIT LIMIT" in upper and "MINIMUM PAYMENT DUE" in upper and v["credit_limit"] is None:
            for nxt in _following(lines, idx):
                m = _ENBD_LIMIT_ROW_RE.match(nxt.strip())
                if m:
                    v["credit_limit"] = _to_decimal(m.group("limit"))
                    v["min_due"] = _to_decimal(m.group("min"))
                    result.due_date = _parse_dmy(m.group("due_date"))
                    break
        elif (
            "PREVIOUS STATEMENT" in upper
            and "PAYMENTS/CREDITS" in upper
            and "CURRENT BALANCE" in upper
            and v["opening_balance"] is None
        ):
            for nxt in _following(lines, idx):
                row = _amount_row(nxt)
                if row and len(row) == 6:
                    prev, purchases_cash, interest_other, credits, _total_due, current = row
                    v["opening_balance"] = prev
                    v["total_debits"] = purchases_cash + interest_other
                    v["total_credits"] = credits
                    v["closing_balance"] = current
                    break


# -------------------------------------------------------------------- ADCB

_ADCB_BALANCE_RE = re.compile(
    rf"(?P<label>PREVIOUS|NEW) BALANCE OUTSTANDING\b.*?(?P<amount>{_DECIMAL_AMOUNT_RE})(?P<cr>\s*CR)?$",
    re.IGNORECASE,
)


def _extract_adcb(lines: list[str], result: TotalsResult) -> None:
    v = result.values
    for line in lines:
        m = _ADCB_BALANCE_RE.search(line.strip())
        if not m:
            continue
        amount = _to_decimal(m.group("amount"))
        if amount is not None and m.group("cr"):
            amount = -abs(amount)
        key = "opening_balance" if m.group("label").upper() == "PREVIOUS" else "closing_balance"
        if v[key] is None:
            v[key] = amount


_EXTRACTORS = {
    "FAB": _extract_fab,
    "ENBD": _extract_enbd,
    "EIB": _extract_enbd,
    "ADCB": _extract_adcb,
}


def extract_totals(bank_code: str, lines: list[str] | None) -> TotalsResult:
    """Extract summary totals from statement text lines. Never raises."""
    result = TotalsResult()
    try:
        if not lines:
            return result
        extractor = _EXTRACTORS.get((bank_code or "").upper())
        if extractor is None:
            return result
        extractor([ln.strip() for ln in lines if ln and ln.strip()], result)
    except Exception as exc:  # noqa: BLE001 - totals are best effort and must never fail a parse
        logger.warning("totals extraction failed for %s: %s", bank_code, type(exc).__name__)
        result = TotalsResult(warnings=[f"Totals extraction failed ({type(exc).__name__}); totals left null"])
    return result


def read_text_lines(pdf_path: Path, passwords: list[str | None]) -> list[str] | None:
    """All page text lines, trying no password first and then each candidate. Never raises."""
    try:
        import pdfplumber  # noqa: PLC0415
    except Exception:  # noqa: BLE001
        return None
    for password in [None, *[p for p in passwords if p]]:
        try:
            kwargs = {"password": password} if password else {}
            with pdfplumber.open(str(pdf_path), **kwargs) as pdf:
                out: list[str] = []
                for page in pdf.pages[: max_pages()]:
                    out.extend((page.extract_text() or "").splitlines())
                return out
        except Exception:  # noqa: BLE001
            continue
    return None
