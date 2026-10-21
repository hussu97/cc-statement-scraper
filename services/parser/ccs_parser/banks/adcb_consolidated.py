"""ADCB "Consolidated Statement of Accounts": bank accounts, their lines and fixed deposits.

The monthly e-statement from estatement@adcb.com covers every product of a customer in one PDF
(password: the customer ID, the ``ADCB_CID`` setting). Page 1 summarises the savings/current
accounts, the fixed deposits and the credit cards; the following pages list each account's
transactions in a table: Date, Description, Chq/Ref No., Value Date, Debit, Credit, Balance.

The table is read from word positions, not text lines: a description wraps over lines printed
above and below its row's date, so ``extract_text`` interleaves them. Each row's amount sits in
the Debit or Credit column and every row prints the running balance, so a row whose balance does
not follow from the previous one is a parse failure, never a guess.

Lines whose description has no known shape keep their amount and direction (``transfer_in`` /
``transfer_out``) and are listed in ``metadata.unrecognised_lines`` by shape only, so the worker
can report them without statement data (CLAUDE.md §6).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.domain.parsing.utils import fingerprint_for, merchant_normalize

BANK_CODE = "ADCB"
BANK_NAME = "Abu Dhabi Central Bank"
TITLE = "Consolidated Statement of Accounts"

# ADCB alerts print the account as XXX + its last six digits (XXX310001): the ledger's account_ref.
ACCOUNT_REF_DIGITS = 6
# A description line belongs to the nearest row date within this distance (points).
_ROW_REACH = 14.0
_LINE_TOLERANCE = 2.0

_DATE = r"\d{2}/\d{2}/\d{4}"
_DATE_RE = re.compile(rf"^{_DATE}$")
_AMOUNT_RE = re.compile(r"^-?[\d,]+\.\d{2}$")
_MONEY = r"-?[\d,]+\.\d{2}"

_SUMMARY_AS_OF_RE = re.compile(rf"Summary of Accounts as on ({_DATE})")
_PERIOD_RE = re.compile(rf"for the period from ({_DATE}) to ({_DATE})")
_ACCOUNT_ROW_RE = re.compile(
    rf"^(?P<number>\d{{8,20}}) (?P<product>.+?) (?P<currency>[A-Z]{{3}}) (?P<balance>{_MONEY}) (?P<balance_aed>{_MONEY})$"
)
_DEPOSIT_ROW_RE = re.compile(
    rf"^(?P<number>\d{{8,20}}) (?P<product>.+?) (?P<currency>[A-Z]{{3}}) (?P<rate>\d{{1,3}}(?:\.\d+)?) "
    rf"(?P<maturity>{_DATE}) (?P<amount>{_MONEY}) (?P<amount_aed>{_MONEY})$"
)
_CARD_ROW_RE = re.compile(
    rf"^[xX*]+(?P<last4>\d{{4}}) (?P<limit>[\d,]+(?:\.\d{{2}})?) (?P<balance>{_MONEY}) (?P<min_due>{_MONEY}) "
    rf"(?P<last_balance>{_MONEY}) (?P<last_date>{_DATE}) (?P<due>{_DATE})$"
)
_ACCOUNT_DETAILS_RE = re.compile(
    r"Account Details:\s*(?P<number>\d{8,20})\s*-\s*(?P<product>.+?)\s+Currency:\s*(?P<currency>[A-Z]{3})"
)
_IBAN_RE = re.compile(r"IBAN:\s*(?P<iban>[A-Z]{2}\d{2}[A-Z0-9]{10,30})")
_TITLE_RE = re.compile(r"Account Title:\s*(?P<title>.+)$")

# Description shapes. A purchase names the card it was made with at the end.
_PURCHASE_RE = re.compile(r"^PUR \d{2}/\d{2} (?P<merchant>.+?)(?: (?P<card>\d{4}))?$")
_FX_FEE_RE = re.compile(r"^FOREIGN TRANSACTION FEE\b")
_TRAILING_CARD_RE = re.compile(r"(?<!\d)(\d{4})$")
_FEE_RE = re.compile(r"\b(FEES?|CHARGES?|COMMISSION|VAT)\b")
_PROFIT_RE = re.compile(r"\bPROFIT\b")


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
    ref_x0: float
    value_x0: float
    debit_credit: float  # x1 at or left of this is Debit
    credit_balance: float  # x1 at or left of this (and right of debit_credit) is Credit


@dataclass
class AccountLine:
    posting_date: date
    value_date: date | None
    description: str
    reference: str | None
    amount: Decimal
    direction: str  # debit | credit
    balance: Decimal


@dataclass
class Account:
    number: str
    product: str
    currency: str
    iban: str | None = None
    title: str | None = None
    opening: Decimal | None = None
    lines: list[AccountLine] = field(default_factory=list)
    total_debits: Decimal | None = None
    total_credits: Decimal | None = None
    warnings: list[str] = field(default_factory=list)

    @property
    def closing(self) -> Decimal | None:
        return self.lines[-1].balance if self.lines else self.opening


@dataclass
class Deposit:
    number: str
    product: str
    currency: str
    rate_pct: Decimal
    maturity_on: date
    amount: Decimal


@dataclass
class CardSummary:
    last4: str
    credit_limit: Decimal
    current_balance: Decimal
    min_due: Decimal
    last_statement_balance: Decimal
    last_statement_date: date
    due_date: date


@dataclass
class Consolidated:
    as_of: date
    period_start: date
    period_end: date
    summary_balances: dict[str, Decimal]
    accounts: list[Account]
    deposits: list[Deposit]
    cards: list[CardSummary]
    warnings: list[str]


# ---------------------------------------------------------------- reading


def _d(raw: str) -> date:
    return datetime.strptime(raw, "%d/%m/%Y").date()


def _money(raw: str) -> Decimal:
    return Decimal(raw.replace(",", ""))


def is_consolidated(text_lines: list[str]) -> bool:
    return any(TITLE.lower() in line.lower() for line in text_lines[:5])


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


def _parse_summary(
    text_lines: list[str],
) -> tuple[date, dict[str, tuple[str, str, Decimal]], list[Deposit], list[CardSummary], list[str]]:
    as_of: date | None = None
    accounts: dict[str, tuple[str, str, Decimal]] = {}
    deposits: list[Deposit] = []
    cards: list[CardSummary] = []
    warnings: list[str] = []
    section: str | None = None
    for line in text_lines:
        if m := _SUMMARY_AS_OF_RE.search(line):
            as_of = _d(m.group(1))
            continue
        if line.startswith("Savings/Current/Call Accounts"):
            section = "accounts"
            continue
        if line.startswith("Fixed Deposits"):
            section = "deposits"
            continue
        if line.startswith("Credit Cards"):
            section = "cards"
            continue
        if line.startswith(("TouchPoints", "Transactions Details")):
            section = None
            continue
        if section is None or line.startswith(("Account Number", "Card Number", "Total", "*")):
            continue
        if section == "accounts" and (m := _ACCOUNT_ROW_RE.match(line)):
            accounts[m["number"]] = (m["product"], m["currency"], _money(m["balance"]))
        elif section == "deposits" and (m := _DEPOSIT_ROW_RE.match(line)):
            deposits.append(
                Deposit(
                    m["number"], m["product"], m["currency"], Decimal(m["rate"]), _d(m["maturity"]), _money(m["amount"])
                )
            )
        elif section == "cards" and (m := _CARD_ROW_RE.match(line)):
            cards.append(
                CardSummary(
                    m["last4"],
                    _money(m["limit"]),
                    _money(m["balance"]),
                    _money(m["min_due"]),
                    _money(m["last_balance"]),
                    _d(m["last_date"]),
                    _d(m["due"]),
                )
            )
        elif section == "accounts" and line[:1].isdigit():
            warnings.append("ADCB consolidated: an account summary row was not understood")
        elif section == "deposits" and line[:1].isdigit():
            warnings.append("ADCB consolidated: a deposit summary row was not understood")
    if as_of is None:
        raise ParserError("UNSUPPORTED_LAYOUT", "ADCB consolidated: no 'Summary of Accounts as on' date.")
    return as_of, accounts, deposits, cards, warnings


# ---------------------------------------------------------------- transactions (word table)


def _header_columns(row: _Row) -> _Columns | None:
    names = {w.text: w for w in row.words}
    if not {"Date", "Description", "Debit", "Credit", "Balance"} <= set(names):
        return None
    # Tight kerning can glue "Chq/Ref No." or "Value Date" into one word.
    ref = next((w for w in row.words if w.text.startswith("Chq")), None)
    value = next((w for w in row.words if w.text.startswith("Value")), None)
    if ref is None or value is None:
        return None
    debit, credit, balance = names["Debit"], names["Credit"], names["Balance"]
    return _Columns(
        ref_x0=ref.x0,
        value_x0=value.x0,
        debit_credit=(debit.x1 + credit.x0) / 2,
        credit_balance=(credit.x1 + balance.x0) / 2,
    )


@dataclass
class _Entry:
    row: _Row
    posting_date: date | None = None  # None for the Total row
    is_brought_forward: bool = False
    is_total: bool = False
    description_rows: list[_Row] = field(default_factory=list)


def _description_words(row: _Row, cols: _Columns, skip_first_date: bool) -> list[str]:
    words = row.words[1:] if skip_first_date else row.words
    return [w.text for w in words if w.x1 <= cols.ref_x0 - 2]


def _amounts(row: _Row, cols: _Columns) -> tuple[Decimal | None, Decimal | None, Decimal | None]:
    debit = credit = balance = None
    for w in row.words:
        if w.x0 < cols.value_x0 or not _AMOUNT_RE.match(w.text):
            continue
        if w.x1 <= cols.debit_credit:
            debit = _money(w.text)
        elif w.x1 <= cols.credit_balance:
            credit = _money(w.text)
        else:
            balance = _money(w.text)
    return debit, credit, balance


def _parse_account_tables(rows: list[_Row]) -> list[Account]:
    accounts: list[Account] = []
    acct: Account | None = None
    cols: _Columns | None = None
    entries: list[_Entry] = []
    loose: list[_Row] = []  # description-column rows in the table, not yet given to a row date
    in_table = False

    def close() -> None:
        nonlocal entries, loose
        if acct is not None and cols is not None:
            _finish_account(acct, entries, loose, cols)
        entries, loose = [], []

    for row in rows:
        text = row.text
        if m := _ACCOUNT_DETAILS_RE.search(text):
            close()
            acct = Account(m["number"], m["product"].strip(), m["currency"])
            accounts.append(acct)
            in_table = False
            continue
        if acct is None:
            continue
        if m := _IBAN_RE.search(text):
            acct.iban = m["iban"]
            continue
        if m := _TITLE_RE.search(text):
            acct.title = m["title"].strip()
            continue
        if (header := _header_columns(row)) is not None:
            cols = header
            in_table = True
            continue
        if text == TITLE:
            continue  # the title repeated at the top of a continuation page
        if text.startswith("End Of Statement"):
            close()
            acct = None
            continue
        if not in_table or cols is None:
            continue
        first = row.words[0]
        if _DATE_RE.match(first.text) and first.x1 < cols.ref_x0:
            entry = _Entry(row, posting_date=_d(first.text))
            entry.is_brought_forward = _description_words(row, cols, True)[:1] == ["B/F"]
            entries.append(entry)
        elif first.text == "Total" and first.x1 < cols.ref_x0:
            entries.append(_Entry(row, is_total=True))
            in_table = False  # the account's table ends at its Total row
        elif first.x1 <= cols.ref_x0 - 2:
            loose.append(row)
    close()
    return accounts


def _finish_account(acct: Account, entries: list[_Entry], loose: list[_Row], cols: _Columns) -> None:
    dated = [e for e in entries if e.posting_date is not None and not e.is_brought_forward]
    # Each wrapped description line goes to the nearest row date on its page; a tie goes to the
    # later row (a two-line description starts above its date).
    for row in loose:
        best: _Entry | None = None
        best_d = _ROW_REACH + 1
        for e in dated:
            if e.row.page != row.page:
                continue
            dist = abs(e.row.top - row.top)
            if dist < best_d or (dist == best_d and best is not None and e.row.top > best.row.top):
                best, best_d = e, dist
        if best is None or best_d > _ROW_REACH:
            acct.warnings.append("a description line was not next to any row; it was left out")
            continue
        best.description_rows.append(row)

    balance: Decimal | None = None
    for e in entries:
        debit, credit, printed = _amounts(e.row, cols)
        if e.is_total:
            acct.total_debits, acct.total_credits = debit, credit
            continue
        if e.is_brought_forward:
            if printed is None:
                raise ParserError("UNSUPPORTED_LAYOUT", "ADCB consolidated: a brought-forward row has no balance.")
            acct.opening = balance = printed
            continue
        if balance is None:
            raise ParserError(
                "UNSUPPORTED_LAYOUT", "ADCB consolidated: an account's rows start without a brought-forward balance."
            )
        if (debit is None) == (credit is None):
            raise ParserError("UNSUPPORTED_LAYOUT", "ADCB consolidated: a row has no single debit or credit amount.")
        amount = debit if debit is not None else credit
        assert amount is not None and e.posting_date is not None
        direction = "debit" if debit is not None else "credit"
        expected = balance - amount if direction == "debit" else balance + amount
        if printed is not None and printed != expected:
            raise ParserError(
                "UNSUPPORTED_LAYOUT",
                "ADCB consolidated: a row's running balance does not follow from the previous row.",
            )
        balance = expected

        parts: list[tuple[float, list[str]]] = [(r.top, _description_words(r, cols, False)) for r in e.description_rows]
        parts.append((e.row.top, _description_words(e.row, cols, True)))
        description = " ".join(t for _, words in sorted(parts, key=lambda p: p[0]) for t in words).strip()
        value_date = next(
            (_d(w.text) for w in e.row.words[1:] if w.x0 >= cols.ref_x0 - 12 and _DATE_RE.match(w.text)), None
        )
        reference = next(
            (
                w.text
                for w in e.row.words
                if cols.ref_x0 - 12 <= w.x0 < cols.value_x0 - 2 and not _DATE_RE.match(w.text)
            ),
            None,
        )
        acct.lines.append(AccountLine(e.posting_date, value_date, description, reference, amount, direction, balance))


def parse_consolidated(text_lines: list[str], words: list[_Word]) -> Consolidated:
    as_of, summary, deposits, cards, warnings = _parse_summary(text_lines)
    period = next((m for line in text_lines if (m := _PERIOD_RE.search(line))), None)
    period_start, period_end = (_d(period.group(1)), _d(period.group(2))) if period else (None, as_of)
    accounts = _parse_account_tables(_rows(words))
    for acct in accounts:
        if acct.opening is None:
            raise ParserError("UNSUPPORTED_LAYOUT", "ADCB consolidated: an account table has no brought-forward row.")
        if acct.number in summary and summary[acct.number][2] != acct.closing and as_of == period_end:
            acct.warnings.append("the closing balance differs from the summary on page 1")
        lines_debits = sum((ln.amount for ln in acct.lines if ln.direction == "debit"), Decimal(0))
        lines_credits = sum((ln.amount for ln in acct.lines if ln.direction == "credit"), Decimal(0))
        if (acct.total_debits is not None and acct.total_debits != lines_debits) or (
            acct.total_credits is not None and acct.total_credits != lines_credits
        ):
            acct.warnings.append("the rows do not add up to the account's Total row")
    listed = {a.number for a in accounts}
    for number in summary:
        if number not in listed:
            warnings.append("an account in the summary has no transaction table")
    if period_start is None:
        warnings.append("ADCB consolidated: no statement period; using the summary date")
    return Consolidated(
        as_of,
        period_start or as_of,
        period_end,
        {k: v[2] for k, v in summary.items()},
        accounts,
        deposits,
        cards,
        warnings,
    )


# ---------------------------------------------------------------- lines → contract


@dataclass
class Classified:
    kind: str
    merchant: str
    card_last4: str | None
    known: bool


def classify(description: str, direction: str) -> Classified:
    """The line's kind from its description; unknown shapes keep only their direction."""
    text = merchant_normalize(description)
    if m := _PURCHASE_RE.match(text):
        return Classified("purchase" if direction == "debit" else "refund", m["merchant"], m["card"], True)
    if _FX_FEE_RE.match(text):
        card = m.group(1) if (m := _TRAILING_CARD_RE.search(text)) else None
        return Classified("fee" if direction == "debit" else "refund", "FOREIGN TRANSACTION FEE", card, True)
    if _FEE_RE.search(text):
        return Classified("fee" if direction == "debit" else "refund", text, None, True)
    if direction == "credit" and _PROFIT_RE.search(text):
        return Classified("interest", text, None, True)
    return Classified("transfer_out" if direction == "debit" else "transfer_in", text, None, False)


def description_shape(description: str) -> str:
    """A description with its content masked: the first word (a transaction code such as PUR or
    IPP) kept, later words as ``w`` and numbers as ``#``. Safe to report (no names, no amounts)."""
    tokens = merchant_normalize(description).split()
    out: list[str] = []
    for i, token in enumerate(tokens[:12]):
        if re.fullmatch(r"[\d/.,:-]+", token):
            out.append("#")
        elif i == 0 and len(token) <= 12 and re.fullmatch(r"[A-Z*&/-]+", token):
            out.append(token)
        else:
            out.append("w")
    return " ".join(out)


def _s(value: Decimal) -> str:
    return f"{abs(value):.2f}"


def _signed(value: Decimal) -> str:
    return "0.00" if value == 0 else f"{value:.2f}"


def account_kind(product: str) -> str:
    return "savings" if re.search(r"\b(SAVER|SAVINGS?|CALL)\b", product.upper()) else "current"


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
            txn_date = ln.value_date or ln.posting_date
            lines.append(
                {
                    "line_no": i,
                    "txn_date": txn_date.isoformat(),
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
                    "card_last4": cl.card_last4,
                    "card_holder": None,
                    "legacy_fingerprint": fingerprint_for(
                        BANK_NAME, cl.card_last4 or acct.number[-4:], ln.posting_date, float(ln.amount), cl.merchant
                    ),
                }
            )
        warnings = list(acct.warnings)
        if unrecognised:
            warnings.append(
                f"{len(unrecognised)} line(s) have a description this parser does not know; "
                "kept as transfers by direction"
            )
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
                "card_holder": acct.title,
                "card_type": None,
                "account": {
                    "kind": account_kind(acct.product),
                    "number": acct.number,
                    "ref": acct.number[-ACCOUNT_REF_DIGITS:],
                    "iban": acct.iban,
                    "product": acct.product,
                    "currency": acct.currency,
                },
                "totals": {
                    "opening_balance": _signed(acct.opening),
                    "closing_balance": _signed(acct.closing),
                    "total_debits": _s(acct.total_debits) if acct.total_debits is not None else None,
                    "total_credits": _s(acct.total_credits) if acct.total_credits is not None else None,
                    "min_due": None,
                    "credit_limit": None,
                },
                "warnings": [*c.warnings, *warnings],
                "metadata": {
                    "pdf_sha256": pdf_sha256,
                    "layout": "adcb_consolidated",
                    "unrecognised_lines": unrecognised,
                },
                "lines": lines,
            }
        )
    return out


def deposits_out(c: Consolidated) -> list[dict[str, Any]]:
    return [
        {
            "number": d.number,
            "product": d.product,
            "currency": d.currency,
            "rate_pct": f"{d.rate_pct:f}",
            "maturity_on": d.maturity_on.isoformat(),
            "amount": _s(d.amount),
            "as_of": c.as_of.isoformat(),
        }
        for d in c.deposits
    ]


def card_summaries_out(c: Consolidated) -> list[dict[str, Any]]:
    return [
        {
            "last4": s.last4,
            "credit_limit": _s(s.credit_limit),
            "current_balance": _signed(s.current_balance),
            "min_due": _s(s.min_due),
            "last_statement_balance": _signed(s.last_statement_balance),
            "last_statement_date": s.last_statement_date.isoformat(),
            "due_date": s.due_date.isoformat(),
            "as_of": c.as_of.isoformat(),
        }
        for s in c.cards
    ]
