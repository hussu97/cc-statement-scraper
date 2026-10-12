"""Best-effort extraction of statement summary totals.

This is new functionality (the legacy backend never extracted totals). It is
deliberately conservative: a value is only returned when the statement text
contains the bank's summary block in the exact layout observed on real PDFs.
Everything else is ``None``. ``extract_totals`` never raises; failures become
warnings.

Verified layouts (against real statements):
  * FAB  -- "Current Balance / Minimum Payment Due" header row, the
            "Previous Balance + Purchases ... Total Payment Due" summary row and
            the "Total Credit Limit / Available Credit Limit" row. The row's
            Payments/Credits column omits rewards redemptions (DP-10).
  * ENBD -- "Credit Limit / Available Credit Limit / Statement Date / Payment
            Due Date / Minimum Payment Due" row and the "STATEMENT SUMMARY" row.
  * MASHREQ -- the "Summary AED" block, one labelled amount per line (DP-12).
  * EIB  -- "Statement of Card Account": the "OPENING BALANCE" line and the
            "Card Limit ... Current Balance (AED)" summary row (2026-10).
  * WIO  -- "Credit Statement": the "Account summary" lines, the credit limit and the
            payment due row (2026-10).
Unverified (no decryptable samples were available):
  * EIB in the ENBD template -- the ENBD rules are applied.
  * ADCB -- "PREVIOUS/NEW BALANCE OUTSTANDING <amount>" lines.
SIB statements have no extractor (all null).
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
    summary_due: Decimal | None = None
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
                    summary_due = total_due
                    break
        elif "TOTAL CREDIT LIMIT" in upper and "AVAILABLE CREDIT LIMIT" in upper and v["credit_limit"] is None:
            for nxt in _following(lines, idx):
                row = _amount_row(nxt)
                if row and len(row) == 2:
                    v["credit_limit"] = row[0]
                    break
    if summary_due is None:
        return
    if v["closing_balance"] is None:
        v["closing_balance"] = summary_due
    _add_fab_other_credits(v, summary_due)


def _add_fab_other_credits(v: dict[str, Decimal | None], total_due: Decimal) -> None:
    """DP-10: FAB's "Payments/Credits" column leaves out other credits.

    Rewards redemptions ("FAB REWARDS REDEMPTION - CASHBACK") and dispute credits are not
    in that column, but "Total Payment Due" (= the Current Balance) already reflects them,
    so the printed row doesn't add up by exactly those amounts. The statement's real credit
    total is what its own row implies: previous + debits - total due. Taken only when the
    row's total due agrees with the Current Balance header and the gap is a missing credit.
    """
    opening, debits, credits, closing = (
        v["opening_balance"],
        v["total_debits"],
        v["total_credits"],
        v["closing_balance"],
    )
    if opening is None or debits is None or credits is None or closing is None or closing != total_due:
        return
    implied = opening + debits - total_due
    if implied > credits:
        v["total_credits"] = implied


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


# --------------------------------------------------------------------- EIB

# The "Statement of Card Account" layout (banks/eib.py). The summary row under
# "Card Limit Available Limit Minimum Payment Due Payment Due Date Total Payment Due
# Profit/Other Charges (AED) Current Balance (AED)" repeats on every page:
#   38,000.00 37,938.21 61.79 25/10/26 61.79 0.00 61.79
# The opening balance is its own line: "OPENING BALANCE 42.72". Debits and credits are
# not printed; the ingest's balance equation checks the lines against these two.
_EIB_SUMMARY_ROW_RE = re.compile(
    rf"^(?P<limit>{_DECIMAL_AMOUNT_RE})\s+(?P<available>{_DECIMAL_AMOUNT_RE}(?:\s*CR)?)\s+"
    rf"(?P<min>{_DECIMAL_AMOUNT_RE})\s+(?P<due_date>\d{{2}}/\d{{2}}/\d{{2}})\s+"
    rf"(?P<total_due>{_DECIMAL_AMOUNT_RE})\s+(?P<charges>{_DECIMAL_AMOUNT_RE})\s+"
    rf"(?P<current>{_DECIMAL_AMOUNT_RE}(?:\s*CR)?)$"
)
_EIB_OPENING_RE = re.compile(rf"^OPENING BALANCE\s+(?P<amount>{_DECIMAL_AMOUNT_RE}(?:\s*CR)?)$", re.IGNORECASE)
_EIB_CARD_SECTION_RE = re.compile(r"^[A-Z][A-Z\- ]*CARD NO\s*[:.]?\s*[\dX* ]*\d{4}$")


def _extract_eib(lines: list[str], result: TotalsResult) -> None:
    if not any("Card Account Number" in line for line in lines[:15]):
        _extract_enbd(lines, result)
        return
    v = result.values
    for idx, line in enumerate(lines):
        stripped = line.strip()
        opening = _EIB_OPENING_RE.match(stripped)
        if opening and v["opening_balance"] is None:
            v["opening_balance"] = _to_decimal(opening.group("amount"))
            continue
        upper = stripped.upper()
        if "CARD LIMIT" in upper and "CURRENT BALANCE" in upper and v["closing_balance"] is None:
            for nxt in _following(lines, idx):
                m = _EIB_SUMMARY_ROW_RE.match(nxt.strip())
                if m:
                    v["credit_limit"] = _to_decimal(m.group("limit"))
                    v["min_due"] = _to_decimal(m.group("min"))
                    v["closing_balance"] = _to_decimal(m.group("current"))
                    try:
                        result.due_date = datetime.strptime(m.group("due_date"), "%d/%m/%y").date()
                    except ValueError:
                        result.warnings.append("EIB: payment due date unreadable")
                    break
    if v["closing_balance"] is None:
        result.warnings.append("EIB: statement summary row not found; balance totals left null")
    elif v["opening_balance"] is None and not any(_EIB_CARD_SECTION_RE.match(ln.strip()) for ln in lines):
        # EIB leaves out the OPENING BALANCE line (and the card section) only in a month
        # with no activity, where the balance carried over unchanged.
        v["opening_balance"] = v["closing_balance"]


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


# ------------------------------------------------------------------ MASHREQ

# The "Summary AED" block prints one labelled amount per line, followed by the Arabic
# label (which pdfplumber extracts as mojibake), e.g. "- other credits 363.00 <arabic> -".
_MASHREQ_AMOUNT = rf"(?P<amount>{_DECIMAL_AMOUNT_RE})(?P<cr>\s*CR)?(?=\s|$)"
_MASHREQ_SUMMARY: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (key, re.compile(rf"^{label}\s+{_MASHREQ_AMOUNT}", re.IGNORECASE))
    for key, label in (
        ("previous", r"previous balance"),
        ("payments", r"-\s*payments"),
        ("other_credits", r"-\s*other credits"),
        ("finance_charges", r"\+\s*finance charges"),
        ("other_charges", r"\+\s*other charges"),
        ("new_transactions", r"\+\s*new transactions"),
        ("cash_advance", r"\+\s*cash advance"),
        ("current", r"[+=]\s*current balance"),
        ("min_due", r"minimum payment due"),
    )
)
# Two-column header lines: the label can follow other text on the same line.
_MASHREQ_LIMIT_RE = re.compile(rf"\bcombined credit limit\s+{_MASHREQ_AMOUNT}", re.IGNORECASE)
_MASHREQ_DUE_DATE_RE = re.compile(r"\bpayment due date\s+(?P<date>\d{2}/\d{2}/\d{4})\b", re.IGNORECASE)


def _mashreq_amount(match: re.Match[str]) -> Decimal | None:
    amount = _to_decimal(match.group("amount"))
    if amount is not None and match.group("cr"):
        amount = -abs(amount)
    return amount


def _extract_mashreq(lines: list[str], result: TotalsResult) -> None:
    """DP-12: Mashreq's "Summary AED" block.

    previous - payments - other credits + finance charges + other charges + new transactions
    + cash advance = current balance. Only taken when every line of the block is present
    and the block adds up, so a partial or mis-read summary leaves the totals null.
    """
    found: dict[str, Decimal | None] = {}
    for line in lines:
        for key, pattern in _MASHREQ_SUMMARY:
            if key in found:
                continue
            m = pattern.match(line)
            if m:
                found[key] = _mashreq_amount(m)
        if "credit_limit" not in found and (m := _MASHREQ_LIMIT_RE.search(line)):
            found["credit_limit"] = _mashreq_amount(m)
        if result.due_date is None and (m := _MASHREQ_DUE_DATE_RE.search(line)):
            result.due_date = _parse_dmy(m.group("date"))

    v = result.values
    v["min_due"] = found.get("min_due")
    v["credit_limit"] = found.get("credit_limit")
    block = (
        "previous",
        "payments",
        "other_credits",
        "finance_charges",
        "other_charges",
        "new_transactions",
        "cash_advance",
        "current",
    )
    if any(found.get(key) is None for key in block):
        if any(key in found for key in block):
            result.warnings.append("MASHREQ: statement summary incomplete; balance totals left null")
        return
    amounts = {key: found[key] for key in block}
    credits = amounts["payments"] + amounts["other_credits"]  # type: ignore[operator]
    debits = (
        amounts["finance_charges"] + amounts["other_charges"] + amounts["new_transactions"] + amounts["cash_advance"]  # type: ignore[operator]
    )
    if amounts["previous"] - credits + debits != amounts["current"]:  # type: ignore[operator]
        result.warnings.append("MASHREQ: statement summary does not add up; balance totals left null")
        return
    v["opening_balance"] = amounts["previous"]
    v["closing_balance"] = amounts["current"]
    v["total_debits"] = debits
    v["total_credits"] = credits


# --------------------------------------------------------------------- WIO

# "Credit Statement" (banks/wio.py). Bilingual from Sep 2026: the Arabic labels are dropped
# (non-ASCII) before matching. The "Account summary" prints one signed amount per line:
#   Balance From Last Statement 0.00 / Purchases +14,805.66 / Interest +0.00 /
#   Late payment fee +0.00 / Foreign exchange charges +2.14 / Payments and credits -14,807.80 /
#   Closing balance (Total to pay) -407.59        (negative: the card is in credit)
_WIO_SUMMARY: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (key, re.compile(rf"^{label}\s+(?P<amount>[+-]?{_DECIMAL_AMOUNT_RE.lstrip('-?')})$", re.IGNORECASE))
    for key, label in (
        ("opening", r"Balance from last statement"),
        ("purchases", r"Purchases"),
        ("interest", r"Interest"),
        ("late_fee", r"Late payment fee"),
        ("fx", r"Foreign exchange charges"),
        ("credits", r"Payments and credits"),
        ("closing", r"Closing balance \(Total to pay\)"),
    )
)
_WIO_DUE_ROW_RE = re.compile(
    rf"(?P<due_date>\d{{2}}/\d{{2}}/\d{{4}})\s+(?P<min>{_DECIMAL_AMOUNT_RE})\s+(?P<total>{_DECIMAL_AMOUNT_RE})$"
)
_WIO_LOOKAHEAD = 6


def _ascii_line(line: str) -> str:
    return re.sub(r"\s+", " ", "".join(ch for ch in line if ord(ch) < 128)).strip()


def _extract_wio(lines: list[str], result: TotalsResult) -> None:
    text = [_ascii_line(ln) for ln in lines]
    v = result.values
    amounts: dict[str, Decimal | None] = {}
    for idx, line in enumerate(text):
        upper = line.upper()
        for key, pattern in _WIO_SUMMARY:
            if key not in amounts and (m := pattern.match(line)):
                amounts[key] = _plain_decimal(m.group("amount").lstrip("+"))
        if "CREDIT LIMIT" in upper and v["credit_limit"] is None:
            for nxt in text[idx + 1 : idx + 1 + _WIO_LOOKAHEAD]:
                row = _amount_row(nxt)
                if row:
                    v["credit_limit"] = row[0]
                    break
        if "PAYMENT DUE DATE" in upper and result.due_date is None:
            for nxt in text[idx + 1 : idx + 1 + _WIO_LOOKAHEAD]:
                m = _WIO_DUE_ROW_RE.search(nxt)
                if m:
                    result.due_date = _parse_dmy(m.group("due_date"))
                    v["min_due"] = _to_decimal(m.group("min"))
                    break
    if len(amounts) < len(_WIO_SUMMARY) or any(a is None for a in amounts.values()):
        result.warnings.append("WIO: account summary incomplete; balance totals left null")
        return
    debits = amounts["purchases"] + amounts["interest"] + amounts["late_fee"] + amounts["fx"]  # type: ignore[operator]
    credits = abs(amounts["credits"])  # type: ignore[arg-type]
    if amounts["opening"] + debits - credits != amounts["closing"]:  # type: ignore[operator]
        result.warnings.append("WIO: account summary does not add up; balance totals left null")
        return
    v["opening_balance"] = amounts["opening"]
    v["closing_balance"] = amounts["closing"]
    v["total_debits"] = debits
    v["total_credits"] = credits


_EXTRACTORS = {
    "FAB": _extract_fab,
    "ENBD": _extract_enbd,
    "EIB": _extract_eib,
    "ADCB": _extract_adcb,
    "MASHREQ": _extract_mashreq,
    "WIO": _extract_wio,
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
