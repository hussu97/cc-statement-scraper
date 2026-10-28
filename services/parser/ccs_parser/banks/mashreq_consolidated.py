"""Mashreq NEO "Consolidated Relationship Statement": current and savings accounts and their lines.

The monthly statement from mashreqstatements@mashreq.com covers every account of a customer in
one PDF (password: the date of birth, ``MASHREQ_PDF_PASSWORD``). Page 1 summarises the accounts;
each account then has its own page(s): "Savings Account Statement" or "Current Account
Statement", its number and IBAN, and a table: Date, Transaction, Reference no, Debit, Credit,
Balance. Amounts print three decimals (fils are two; the third is always 0).

The table is read from word positions. A row's description is a cell of one or more lines,
vertically centred on the row's amounts, so a long description starts above its date. Every
row prints Debit, Credit and Balance; a row with no date and all three zero is narration for the
row above it ("FROM ACCOUNT No:… TO ACCOUNT No:…"). OPENING and CLOSING BALANCE rows bound the
table, and every dated row's balance must follow from the last or the parse fails.

Lines whose description has no known shape keep their amount and direction (``transfer_in`` /
``transfer_out``) and are listed in ``metadata.unrecognised_lines`` by shape only (CLAUDE.md §6).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

from ccs_parser.banks.adcb_consolidated import description_shape
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.domain.parsing.utils import fingerprint_for, merchant_normalize

BANK_CODE = "MASHREQ"
BANK_NAME = "Mashreq Bank"
TITLE = "Consolidated Relationship Statement"

# Mashreq alerts mask an account to its last four digits: the ledger's account_ref.
ACCOUNT_REF_DIGITS = 4
_LINE_TOLERANCE = 2.0
# A date, reference or amount belongs to the amounts row within this distance (points): the
# column a row's amount is not in prints 0.000 a little higher than the others.
_ROW_REACH = 5.0
# Assigning no description to a row costs this much (points of centring error), so an empty
# cell is chosen only when every alternative is worse.
_EMPTY_CELL_COST = 40.0
# The summary's product name wraps onto the lines just above and below its account number.
_PRODUCT_REACH = 14.0
# The address block (name first) is left of the title block, which starts near x = 267.
_ADDRESS_X1 = 250.0

_DATE_RE = re.compile(r"^\d{2}/\d{2}/\d{4}$")
_AMOUNT_RE = re.compile(r"^-?[\d,]+\.\d{2,3}$")
_PERIOD_RE = re.compile(r"Statement (?:for )?Period (\d{2}/\d{2}/\d{4}) to (\d{2}/\d{2}/\d{4})")
# The address block on the left shares lines with these labels, so they are searched, not matched.
_SECTION_RE = re.compile(r"\b(?P<kind>Savings|Current) Account Statement\b")
_OTHER_SECTION_RE = re.compile(r"^[A-Z][A-Za-z ]+ Statement$")
_ACCOUNT_NO_RE = re.compile(r"\bAccount No (?P<number>\d{8,20}) (?P<currency>[A-Z]{3})\b")
_IBAN_RE = re.compile(r"\bIBAN (?P<iban>[A-Z]{2}\d{2}[A-Z0-9]{10,30})\b")
_PAGE_RE = re.compile(r"^Page \d+ of \d+$")

# Description shapes. A row booked on another day than its value date starts "VALUE DATE: dd-mm-yyyy".
_VALUE_DATE_PREFIX_RE = re.compile(r"^VALUE DATE:?\s*\d{2}-\d{2}-\d{4}\s+")
_INTEREST_RE = re.compile(r"\bINTEREST\b")
_OWN_TRANSFER_RE = re.compile(r"^ACCOUNT TO ACCOUNT TRANSFER\b")
_IPP_RE = re.compile(r"^IPP TRANSFER\b")
_REMITTANCE_RE = re.compile(r"^(?P<way>INWARD|OUTWARD) REMITTANCE\b")
_FEE_RE = re.compile(r"\b(FEES?|CHARGES?|COMMISSION|VAT)\b")


@dataclass
class _Word:
    page: int
    x0: float
    x1: float
    top: float
    text: str


@dataclass
class _Row:
    page: int
    top: float
    words: list[_Word]

    @property
    def text(self) -> str:
        return " ".join(w.text for w in self.words)


@dataclass
class _Columns:
    desc_x0: float
    ref_x0: float
    debit_x1: float
    credit_x1: float
    balance_x1: float


@dataclass
class _Anchor:
    """A table row: its amounts, and the date, reference and description cell around them."""

    top: float
    debit: Decimal
    credit: Decimal
    balance: Decimal
    posting_date: date | None = None
    reference: list[str] = field(default_factory=list)
    cell: list[_Row] = field(default_factory=list)

    @property
    def description(self) -> str:
        return " ".join(r.text for r in self.cell).strip()


@dataclass
class AccountLine:
    posting_date: date
    description: str
    reference: str | None
    amount: Decimal
    direction: str  # debit | credit
    balance: Decimal


@dataclass
class Account:
    number: str
    kind: str  # savings | current
    currency: str
    product: str
    iban: str | None = None
    opening: Decimal | None = None
    closing: Decimal | None = None
    lines: list[AccountLine] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


@dataclass
class Consolidated:
    holder: str | None
    period_start: date
    period_end: date
    accounts: list[Account]
    warnings: list[str]


# ---------------------------------------------------------------- reading


def _d(raw: str) -> date:
    return datetime.strptime(raw, "%d/%m/%Y").date()


def _money(raw: str) -> Decimal:
    value = Decimal(raw.replace(",", ""))
    if value != value.quantize(Decimal("0.01")):
        raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: an amount has fractions of a fils.")
    return value.quantize(Decimal("0.01"))


def is_consolidated(text_lines: list[str]) -> bool:
    return any(line.startswith(TITLE) for line in text_lines[:5])


def read_pdf(pdf_path: str | Path, passwords: list[str | None]) -> tuple[list[str], list[_Word]] | None:
    """Text lines and words of the PDF, or None when no password opens it."""
    import pdfplumber  # noqa: PLC0415

    for password in [p for p in passwords if p] or [None]:
        try:
            kwargs: dict[str, Any] = {"password": password} if password else {}
            with pdfplumber.open(str(pdf_path), **kwargs) as pdf:
                lines: list[str] = []
                words: list[_Word] = []
                for page_no, page in enumerate(pdf.pages, 1):
                    lines.extend(ln.strip() for ln in (page.extract_text() or "").splitlines() if ln.strip())
                    if page_no == 1 and not is_consolidated(lines):
                        return lines, []  # a card statement: the caller moves on
                    words.extend(
                        _Word(page_no, float(w["x0"]), float(w["x1"]), float(w["top"]), w["text"])
                        for w in page.extract_words()
                        # The statement repeats every label in Arabic, which extracts as glyph
                        # soup; only ASCII words carry the table.
                        if w["text"].isascii() and "(cid:" not in w["text"]
                    )
                return lines, words
        except Exception:  # noqa: BLE001
            continue
    return None


def _rows(words: list[_Word]) -> list[_Row]:
    """Words grouped into visual lines (same page, same baseline), top to bottom, left to right."""
    rows: list[_Row] = []
    for w in sorted(words, key=lambda w: (w.page, w.top, w.x0)):
        if rows and rows[-1].page == w.page and abs(rows[-1].top - w.top) <= _LINE_TOLERANCE:
            rows[-1].words.append(w)
        else:
            rows.append(_Row(w.page, w.top, [w]))
    for row in rows:
        row.words.sort(key=lambda w: w.x0)
    return rows


# ---------------------------------------------------------------- summary (page 1)


def _summary_products(words: list[_Word]) -> dict[str, str]:
    """Each account's product name from page 1's summary ("Neo Plus Saver - Balance").

    The name sits left of the account number and may wrap onto lines above and below it.
    """
    page1 = [w for w in words if w.page == 1]
    products: dict[str, str] = {}
    for number in (w for w in page1 if re.fullmatch(r"\d{12,20}", w.text)):
        name = [
            w
            for w in page1
            if w.x1 < number.x0 - 3 and abs(w.top - number.top) <= _PRODUCT_REACH and not w.text.startswith("IBAN")
        ]
        if name:
            products[number.text] = " ".join(w.text for w in sorted(name, key=lambda w: (w.top, w.x0)))
    return products


def _holder(rows: list[_Row]) -> str | None:
    """The customer's name: the first line of page 1's address block, left of the title block."""
    for row in rows:
        if row.page != 1:
            break
        if left := [w.text for w in row.words if w.x1 < _ADDRESS_X1]:
            return " ".join(left)
    return None


# ---------------------------------------------------------------- transactions (word table)


def _header_columns(row: _Row) -> _Columns | None:
    names = {w.text: w for w in row.words}
    if not {"Date", "Transaction", "Reference", "Debit", "Credit", "Balance"} <= set(names):
        return None
    return _Columns(
        desc_x0=names["Transaction"].x0,
        ref_x0=names["Reference"].x0,
        debit_x1=names["Debit"].x1,
        credit_x1=names["Credit"].x1,
        balance_x1=names["Balance"].x1,
    )


def _amount_column(w: _Word, cols: _Columns) -> str | None:
    """Amounts are right-aligned under their header."""
    if not _AMOUNT_RE.match(w.text):
        return None
    edges = {"debit": cols.debit_x1, "credit": cols.credit_x1, "balance": cols.balance_x1}
    name, edge = min(edges.items(), key=lambda kv: abs(kv[1] - w.x1))
    return name if abs(edge - w.x1) <= 8 else None


def _assign_cells(anchors: list[_Anchor], lines: list[_Row]) -> None:
    """Give each anchor a contiguous run of description lines, centred on it as well as possible.

    A cell's lines are centred on its row's amounts; consecutive cells can sit as close as two
    lines within a cell, so gaps alone can't split them. The split minimises the summed distance
    between each cell's centre and its anchor (a small dynamic programme, one page at a time).
    A line on an anchor's own baseline is always that anchor's; an exact tie gives a line to the
    earlier anchor.
    """
    n, m = len(anchors), len(lines)
    inf = float("inf")
    pinned: list[int | None] = [
        next((j for j, a in enumerate(anchors) if abs(a.top - ln.top) <= _LINE_TOLERANCE), None) for ln in lines
    ]
    # best[j][k]: least cost giving lines[:k] to anchors[:j]; choice[j][k]: where anchor j-1's run began.
    best = [[inf] * (m + 1) for _ in range(n + 1)]
    choice = [[0] * (m + 1) for _ in range(n + 1)]
    best[0][0] = 0.0
    for j in range(1, n + 1):
        top = anchors[j - 1].top
        for k in range(m + 1):
            for start in range(k + 1):
                if best[j - 1][start] == inf:
                    continue
                # Lines before this run went to earlier anchors, lines after it go to later ones.
                if any(p is not None and p != j - 1 for p in pinned[start:k]) or any(
                    p is not None and p >= j - 1 for p in pinned[:start]
                ):
                    continue
                if start == k:
                    cost = _EMPTY_CELL_COST
                else:
                    cost = abs((lines[start].top + lines[k - 1].top) / 2 - top)
                total = best[j - 1][start] + cost
                if total <= best[j][k]:
                    best[j][k], choice[j][k] = total, start
    if best[n][m] == inf:
        raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: the table's descriptions could not be placed.")
    k = m
    for j in range(n, 0, -1):
        start = choice[j][k]
        anchors[j - 1].cell = lines[start:k]
        k = start


def _page_anchors(rows: list[_Row], cols: _Columns) -> list[_Anchor]:
    """The table rows of one page's table: amounts rows, with their dates, references and cells."""
    amount_rows: list[tuple[float, dict[str, tuple[float, Decimal]]]] = []
    dates: list[_Word] = []
    refs: list[_Word] = []
    desc_lines: list[_Row] = []
    for row in rows:
        desc = [w for w in row.words if cols.desc_x0 - 3 <= w.x0 < cols.ref_x0 - 3]
        for w in row.words:
            if w.x1 < cols.desc_x0 - 3 and _DATE_RE.match(w.text):
                dates.append(w)
            elif cols.ref_x0 - 3 <= w.x0 and (column := _amount_column(w, cols)) is not None:
                amount_rows.append((w.top, {column: (w.top, _money(w.text))}))
            elif cols.ref_x0 - 3 <= w.x0 < cols.debit_x1 - 60:
                refs.append(w)
        if desc:
            desc_lines.append(_Row(row.page, row.top, desc))

    # The three amounts of a row print at slightly different heights: merge by distance.
    merged: list[tuple[float, dict[str, tuple[float, Decimal]]]] = []
    for top, amounts in sorted(amount_rows, key=lambda r: r[0]):
        if merged and top - merged[-1][0] <= _ROW_REACH and not (set(amounts) & set(merged[-1][1])):
            merged[-1][1].update(amounts)
        else:
            merged.append((top, dict(amounts)))
    anchors: list[_Anchor] = []
    for _, amounts in merged:
        if set(amounts) != {"debit", "credit", "balance"}:
            raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: a row does not print all three amounts.")
        # The balance is always on the row's baseline; a zero Debit or Credit may sit higher.
        top = amounts["balance"][0]
        anchors.append(_Anchor(top, amounts["debit"][1], amounts["credit"][1], amounts["balance"][1]))
    for a in anchors:
        near = [w for w in dates if abs(w.top - a.top) <= _ROW_REACH]
        if len(near) > 1:
            raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: a row has two dates.")
        a.posting_date = _d(near[0].text) if near else None
    if len(dates) != sum(1 for a in anchors if a.posting_date is not None):
        raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: a date is not on any row's amounts.")
    for w in refs:
        nearest = min(anchors, key=lambda a: abs(a.top - w.top), default=None)
        if nearest is not None:
            nearest.reference.append(w.text)
    _assign_cells(anchors, desc_lines)
    return anchors


def _apply_anchors(acct: Account, anchors: list[_Anchor]) -> bool:
    """Fold one page's rows into the account; True once its CLOSING BALANCE row was read."""
    for a in anchors:
        text = merchant_normalize(a.description)
        if a.posting_date is None and text.startswith("OPENING BALANCE"):
            if acct.opening is not None:
                raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: an account has two opening balances.")
            acct.opening = a.balance
            continue
        if acct.opening is None:
            raise ParserError(
                "UNSUPPORTED_LAYOUT", "Mashreq consolidated: an account's rows start without an opening balance."
            )
        balance = acct.lines[-1].balance if acct.lines else acct.opening
        if a.posting_date is None and text.startswith("CLOSING BALANCE"):
            if a.balance != balance:
                raise ParserError(
                    "UNSUPPORTED_LAYOUT", "Mashreq consolidated: the closing balance does not follow from the rows."
                )
            acct.closing = a.balance
            return True
        if a.posting_date is None:
            if a.debit or a.credit or a.balance:
                raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: an undated row carries an amount.")
            if not acct.lines:
                raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: narration before the first row.")
            last = acct.lines[-1]
            last.description = f"{last.description} {a.description}".strip()
            continue
        if (a.debit != 0) == (a.credit != 0):
            raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: a row has no single debit or credit amount.")
        direction = "debit" if a.debit else "credit"
        amount = a.debit if a.debit else a.credit
        expected = balance - amount if direction == "debit" else balance + amount
        if a.balance != expected:
            raise ParserError(
                "UNSUPPORTED_LAYOUT",
                "Mashreq consolidated: a row's running balance does not follow from the previous row.",
            )
        acct.lines.append(
            AccountLine(a.posting_date, a.description, " ".join(a.reference) or None, amount, direction, a.balance)
        )
    return False


def _parse_accounts(rows: list[_Row], products: dict[str, str], warnings: list[str]) -> list[Account]:
    accounts: dict[str, Account] = {}
    by_page: dict[int, list[_Row]] = {}
    for row in rows:
        by_page.setdefault(row.page, []).append(row)
    for page, page_rows in sorted(by_page.items()):
        if page == 1:
            continue
        kind: str | None = None
        other_section = False
        acct: Account | None = None
        cols: _Columns | None = None
        table: list[_Row] = []
        for row in page_rows:
            text = row.text
            if m := _SECTION_RE.search(text):
                kind = m["kind"].lower()
                continue
            if cols is None and _OTHER_SECTION_RE.search(text) and "Account Statement" not in text:
                other_section = True
                continue
            if (m := _ACCOUNT_NO_RE.search(text)) and kind is not None:
                number = m["number"]
                acct = accounts.get(number)
                if acct is None:
                    product = products.get(number) or f"Mashreq {kind.title()} Account"
                    acct = accounts[number] = Account(number, kind, m["currency"], product)
                continue
            if (m := _IBAN_RE.search(text)) and acct is not None:
                acct.iban = m["iban"]
                continue
            if acct is not None and (header := _header_columns(row)) is not None:
                cols = header
                continue
            if cols is not None and not _PAGE_RE.match(text):
                table.append(row)
        if other_section and acct is None:
            warnings.append("Mashreq consolidated: a statement section this parser does not read was skipped")
            continue
        if acct is None or cols is None:
            continue
        if acct.closing is not None:
            raise ParserError(
                "UNSUPPORTED_LAYOUT", "Mashreq consolidated: an account's table continues after its closing balance."
            )
        _apply_anchors(acct, _page_anchors(table, cols))
    for acct in accounts.values():
        if acct.opening is None or acct.closing is None:
            raise ParserError(
                "UNSUPPORTED_LAYOUT", "Mashreq consolidated: an account table has no opening or closing balance."
            )
    return list(accounts.values())


def parse_consolidated(text_lines: list[str], words: list[_Word]) -> Consolidated:
    period = next((m for line in text_lines if (m := _PERIOD_RE.search(line))), None)
    if period is None:
        raise ParserError("UNSUPPORTED_LAYOUT", "Mashreq consolidated: no statement period.")
    rows = _rows(words)
    warnings: list[str] = []
    accounts = _parse_accounts(rows, _summary_products(words), warnings)
    return Consolidated(_holder(rows), _d(period.group(1)), _d(period.group(2)), accounts, warnings)


# ---------------------------------------------------------------- lines → contract


@dataclass
class Classified:
    kind: str
    merchant: str
    known: bool


def classify(description: str, direction: str) -> Classified:
    """The line's kind from its description; unknown shapes keep only their direction."""
    text = _VALUE_DATE_PREFIX_RE.sub("", merchant_normalize(description))
    transfer = "transfer_out" if direction == "debit" else "transfer_in"
    if _OWN_TRANSFER_RE.match(text):
        return Classified(transfer, "ACCOUNT TO ACCOUNT TRANSFER", True)
    if _IPP_RE.match(text):
        return Classified(transfer, "IPP TRANSFER", True)
    if m := _REMITTANCE_RE.match(text):
        return Classified(transfer, f"{m['way']} REMITTANCE", True)
    if _INTEREST_RE.search(text):
        return Classified("interest", "INTEREST", True)
    if _FEE_RE.search(text):
        return Classified("fee" if direction == "debit" else "refund", text, True)
    return Classified(transfer, text, False)


def _s(value: Decimal) -> str:
    return f"{abs(value):.2f}"


def _signed(value: Decimal) -> str:
    return "0.00" if value == 0 else f"{value:.2f}"


def statements_out(c: Consolidated, pdf_sha256: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for acct in c.accounts:
        lines: list[dict[str, Any]] = []
        unrecognised: list[dict[str, Any]] = []
        for i, ln in enumerate(acct.lines, 1):
            cl = classify(ln.description, ln.direction)
            if not cl.known:
                unrecognised.append(
                    {"line_no": i, "direction": ln.direction, "shape": description_shape(ln.description)}
                )
            lines.append(
                {
                    "line_no": i,
                    "txn_date": ln.posting_date.isoformat(),
                    "txn_time": None,
                    "posting_date": ln.posting_date.isoformat(),
                    "description_raw": ln.description,
                    "merchant_normalized": cl.merchant,
                    "amount_original": _s(ln.amount),
                    "currency_original": acct.currency,
                    "amount_aed": _s(ln.amount) if acct.currency == "AED" else None,
                    "fx_rate": "1" if acct.currency == "AED" else None,
                    "direction": ln.direction,
                    "kind": cl.kind,
                    "country_code": None,
                    "card_last4": None,
                    "card_holder": None,
                    "legacy_fingerprint": fingerprint_for(
                        BANK_NAME, acct.number[-4:], ln.posting_date, float(ln.amount), cl.merchant
                    ),
                }
            )
        warnings = list(acct.warnings)
        if unrecognised:
            warnings.append(
                f"{len(unrecognised)} line(s) have a description this parser does not know; "
                "kept as transfers by direction"
            )
        debits = sum((ln.amount for ln in acct.lines if ln.direction == "debit"), Decimal(0))
        credits = sum((ln.amount for ln in acct.lines if ln.direction == "credit"), Decimal(0))
        assert acct.opening is not None and acct.closing is not None
        out.append(
            {
                "kind": "statement",
                "bank_code": BANK_CODE,
                "statement_reference": f"{acct.number}-{c.period_end:%Y%m%d}",
                "reference_source": "fallback",
                "statement_date": c.period_end.isoformat(),
                "period_start": c.period_start.isoformat(),
                "period_end": c.period_end.isoformat(),
                "due_date": None,
                "primary_card_last4": None,
                "card_holder": c.holder,
                "card_type": None,
                "account": {
                    "kind": acct.kind,
                    "number": acct.number,
                    "ref": acct.number[-ACCOUNT_REF_DIGITS:],
                    "iban": acct.iban,
                    "product": acct.product,
                    "currency": acct.currency,
                },
                "totals": {
                    "opening_balance": _signed(acct.opening),
                    "closing_balance": _signed(acct.closing),
                    "total_debits": _s(debits),
                    "total_credits": _s(credits),
                    "min_due": None,
                    "credit_limit": None,
                },
                "warnings": [*c.warnings, *warnings],
                "metadata": {
                    "pdf_sha256": pdf_sha256,
                    "layout": "mashreq_consolidated",
                    "unrecognised_lines": unrecognised,
                },
                "lines": lines,
            }
        )
    return out
