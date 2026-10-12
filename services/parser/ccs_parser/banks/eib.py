from __future__ import annotations

import re
from datetime import date, datetime
from pathlib import Path

import pdfplumber

from ccs_parser.domain.parsing.models import StatementParseResult, TransactionRecord
from ccs_parser.domain.parsing.utils import (
    classify_transaction_kind,
    extract_last4_masked,
    fingerprint_for,
    merchant_normalize,
    parse_amount,
    parse_date,
    statement_month_from_date,
)
from ccs_parser.domain.parsing.period_years import resolve_period_years
from ccs_parser.totals import _ENBD_LIMIT_ROW_RE

BANK_CODE = "EIB"
BANK_NAME = "Emirates Islamic Bank"

_ROW_RE = re.compile(
    r"^(?P<txn_date>\d{2}/\d{2}/\d{4})\s+"
    r"(?P<posting_date>\d{2}/\d{2}/\d{4})\s+"
    r"(?P<description>.+?)\s+"
    r"(?P<amount_aed>[\d,]+\.\d{2})(?P<amount_suffix>\s*(?:CR|DR))?$",
    re.IGNORECASE,
)

_STATEMENT_PERIOD_RE = re.compile(r"Statement Period:\s*(\d{2}-[A-Za-z]{3}-\d{2})\s+to\s+(\d{2}-[A-Za-z]{3}-\d{2})")
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


# ------------------------------------------------- "Statement of Card Account" layout
# The layout EIB actually sends (first real sample: an Amazon World Mastercard, Sep 2026).
# Bilingual pages; pdfplumber yields the English text with the Arabic interleaved.
#   From:1st Sep 2026 / To:30th Sep 2026              (period, on separate lines)
#   Card Account Number.: 5424 XXXX XXXX 9216
#   OPENING BALANCE 42.72
#   PRIMARY CARD NO:5424XXXXXXXX9216                  (a card section; supplementary too)
#   01 SEP 31 AUG *UBER DOWNTOWN EGY 169.98 EGP 12.87 (POST date first, then TRXN date)
#   *(1 AED = EGP 13.20746)                           (the rate of the row above)
#   20 SEP 19 SEP AMAZON RETAIL DUBAI ARE 5,259.00CR
# Rows carry no year; it comes from the period end.
# The bilingual header extracts in a varying order (same card, different months):
#   "SAMPLE HOLDER Card Account Number.: 5424 XXXX XXXX 9216" or the number on the name
#   line ("CAROL SAMPLE <arabic> 5424 XXXX XXXX 9216 PAGE 1 OF 3") with a bare
#   "Card Account Number.:"; "To:30th Jun 2026" or "30th Jun 2026" followed by "To:".
# A month with no activity has no OPENING BALANCE line and no card section.

_CARD_ACCOUNT_MARKER = "Card Account Number"
_HEADER_LINES = 15
_CA_PERIOD_RE = re.compile(
    r"^(?:(?P<label>From|To):\s*)?(?P<day>\d{1,2})(?:st|nd|rd|th)\s+(?P<month>[A-Za-z]{3})[A-Za-z]*\s+(?P<year>\d{4})$",
)
_CA_ACCOUNT_RE = re.compile(r"Card Account Number\.?:\s*([\dX ]*\d{4})\b")
_CA_MASKED_RE = re.compile(r"\b\d{4} ?X{4} ?X{4} ?(\d{4})\b")
_CA_SECTION_RE = re.compile(r"^(?P<role>[A-Z][A-Z\- ]*?)\s*CARD NO\s*[:.]?\s*[\dX* ]*?(?P<last4>\d{4})$")
_CA_OPENING_RE = re.compile(r"^OPENING BALANCE\s+(?P<amount>[\d,]+\.\d{2})(?P<cr>\s*CR)?$", re.IGNORECASE)
_CA_ROW_RE = re.compile(
    r"^(?P<post>\d{2} [A-Z]{3})\s+(?P<txn>\d{2} [A-Z]{3})\s+(?P<description>.+?)\s+"
    r"(?P<amount>[\d,]+\.\d{2})(?P<cr>\s*CR)?$"
)
# The original amount and currency close the description of a foreign row; the next
# line's rate confirms the currency, so a description ending "... 24 ARE" stays text.
_CA_FOREIGN_TAIL_RE = re.compile(r"^(?P<merchant>.+?)\s+(?P<amount>[\d,]+(?:\.\d{1,3})?)\s+(?P<currency>[A-Z]{3})$")
_CA_RATE_RE = re.compile(r"^\*?\(\s*1 AED\s*=\s*(?P<currency>[A-Z]{3})\s+(?P<rate>\d+(?:\.\d+)?)\s*\)$")


def _is_card_account_layout(lines: list[str]) -> bool:
    return any(_CARD_ACCOUNT_MARKER in line for line in lines[:_HEADER_LINES])


def _ca_period(lines: list[str]) -> tuple[date | None, date | None]:
    """(start, end): the "From:" date, then the next printed date (labelled "To:" or not)."""
    start: date | None = None
    end: date | None = None
    for line in lines[: _HEADER_LINES + 10]:
        match = _CA_PERIOD_RE.match(line)
        if not match:
            continue
        value = _ca_period_date(match)
        if match["label"] == "From" and start is None:
            start = value
        elif match["label"] != "From" and end is None:
            end = value
    return start, end


def _ca_account_last4(lines: list[str]) -> str | None:
    header = lines[:_HEADER_LINES]
    for line in header:
        match = _CA_ACCOUNT_RE.search(line)
        if match:
            return match.group(1)[-4:]
    for line in header:
        match = _CA_MASKED_RE.search(line)
        if match:
            return match.group(1)
    return None


def _ca_period_date(match: re.Match[str]) -> date | None:
    try:
        return datetime.strptime(f"{match['day']} {match['month']} {match['year']}", "%d %b %Y").date()
    except ValueError:
        return None


def _ca_row_date(token: str, period_end: date) -> date | None:
    """A "DD MON" row date in the year that puts it on or before the period end."""
    try:
        parsed = datetime.strptime(f"{token} {period_end.year}", "%d %b %Y").date()
    except ValueError:
        return None
    if parsed > period_end:
        try:
            parsed = parsed.replace(year=parsed.year - 1)
        except ValueError:
            return None
    return parsed


def _ca_card_holder(lines: list[str]) -> str | None:
    """The name, printed over the two lines after "Statement of Card Account" with the
    account label, the card number or the address between its parts. Only the leading
    upper-case words of each of the next three lines count; at most two parts."""
    for idx, line in enumerate(lines[:_HEADER_LINES]):
        if "Statement of Card Account" not in line:
            continue
        parts = [_leading_name(nxt) for nxt in lines[idx + 1 : idx + 4]]
        name = " ".join([p for p in parts if p][:2])
        return name or None
    return None


def _leading_name(text: str) -> str:
    words: list[str] = []
    for word in text.split():
        if not re.fullmatch(r"[A-Z][A-Z.'\-]*", word) or word in {"PAGE", "STATEMENT"}:
            break
        words.append(word)
    return " ".join(words)


def _parse_card_account_layout(path: Path, lines: list[str]) -> StatementParseResult:
    period_start, period_end = _ca_period(lines)
    if period_end is None:
        # No year anywhere else: without the period end no row date can be placed.
        return StatementParseResult(
            bank_code=BANK_CODE,
            bank_name=BANK_NAME,
            source_pdf=path,
            statement_month="1970-01",
            transactions=[],
            warnings=["EIB: statement period not found"],
            metadata={"card_last4": None},
        )

    account_last4 = _ca_account_last4(lines)
    card_holder = _ca_card_holder(lines)
    statement_month = statement_month_from_date(period_end)

    warnings: list[str] = []
    transactions: list[TransactionRecord] = []
    current_last4 = account_last4 or "0000"
    for idx, line in enumerate(lines):
        section = _CA_SECTION_RE.match(line)
        if section:
            current_last4 = section["last4"]
            continue
        row = _CA_ROW_RE.match(line)
        if not row:
            continue
        posting_date = _ca_row_date(row["post"], period_end)
        txn_date = _ca_row_date(row["txn"], period_end)
        if posting_date is None or txn_date is None:
            warnings.append(f"EIB: unreadable row date skipped ({row['post']} / {row['txn']})")
            continue

        description = row["description"].strip()
        amount_aed = parse_amount(row["amount"])
        if row["cr"]:
            amount_aed = -amount_aed

        currency = "AED"
        amount_original = amount_aed
        fx_rate_to_aed = 1.0
        rate = _CA_RATE_RE.match(lines[idx + 1]) if idx + 1 < len(lines) else None
        tail = _CA_FOREIGN_TAIL_RE.match(description) if rate else None
        if rate and tail and tail["currency"] == rate["currency"] and float(rate["rate"]) > 0:
            description = tail["merchant"].strip()
            currency = tail["currency"]
            original = parse_amount(tail["amount"])
            amount_original = -original if amount_aed < 0 else original
            # Printed as "1 AED = <rate> <CUR>"; the contract wants AED per unit.
            fx_rate_to_aed = 1 / float(rate["rate"])
        elif rate:
            warnings.append(f"EIB: rate line for {rate['currency']} did not match its row; kept as AED")

        merchant_norm = merchant_normalize(description)
        kind = classify_transaction_kind(merchant_norm, amount_aed)
        # The shared rule calls every unlabelled credit a payment (other banks' history
        # depends on it). Here a merchant credit ("AMAZON RETAIL DUBAI ARE 5,259.00CR")
        # is a refund; only a row that says PAYMENT is a payment. No legacy EIB data exists.
        if kind == "payment" and "PAYMENT" not in merchant_norm.upper():
            kind = "refund"
        transactions.append(
            TransactionRecord(
                bank_name=BANK_NAME,
                card_last4=current_last4,
                card_holder=card_holder,
                card_type=None,
                statement_month=statement_month,
                transaction_date=txn_date,
                posting_date=posting_date,
                merchant_raw=description,
                merchant_normalized=merchant_norm,
                country_code=_extract_country_code(description),
                amount_original=amount_original,
                currency_original=currency,
                amount_aed=amount_aed,
                fx_rate_to_aed=fx_rate_to_aed,
                transaction_kind=kind,
                source_pdf=str(path),
                fingerprint=fingerprint_for(BANK_NAME, current_last4, posting_date, amount_aed, merchant_norm),
            )
        )

    if not transactions:
        # A month without activity prints neither an opening balance nor a card section;
        # anything else without rows is a layout the parser does not read.
        has_activity_markers = any(_CA_SECTION_RE.match(ln) or _CA_OPENING_RE.match(ln) for ln in lines)
        warnings.append(
            "No EIB transaction rows matched expected pattern"
            if has_activity_markers
            else "EIB: no activity this period (no opening balance or card section printed)"
        )

    return StatementParseResult(
        bank_code=BANK_CODE,
        bank_name=BANK_NAME,
        source_pdf=path,
        statement_month=statement_month,
        transactions=transactions,
        warnings=warnings,
        metadata={
            "card_last4": account_last4,
            "card_holder": card_holder,
            "card_type": None,
            "statement_period_start": period_start.isoformat() if period_start else None,
            "statement_period_end": period_end.isoformat(),
            "statement_date": period_end.isoformat(),
            "statement_reference": None,
        },
    )


def parse_eib_statement(pdf_path: str | Path, pdf_password: str | None = None) -> StatementParseResult:
    path = Path(pdf_path)

    # An encrypted PDF without the right password raises here; the service maps it
    # to PDF_DECRYPT_FAILED (audit X-17).
    open_kwargs: dict = {"password": pdf_password} if pdf_password else {}
    with pdfplumber.open(str(path), **open_kwargs) as pdf:
        lines: list[str] = []
        for page in pdf.pages:
            page_lines = [ln.strip() for ln in (page.extract_text() or "").splitlines() if ln.strip()]
            lines.extend(page_lines)

    if _is_card_account_layout(lines):
        return _parse_card_account_layout(path, lines)

    # The Emirates NBD group template (never seen from EIB yet; kept for that layout).
    card_last4 = "0000"
    card_holder: str | None = None
    card_type: str | None = None
    statement_month: str | None = None
    period_start = None
    period_end = None
    summary_statement_date = None

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

        summary_match = _ENBD_LIMIT_ROW_RE.match(line)
        if summary_match and summary_statement_date is None:
            try:
                summary_statement_date = parse_date(summary_match.group("statement_date"), "%d/%m/%Y")
            except ValueError:
                summary_statement_date = None
            continue

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

    # The printed period uses 2-digit years that are wrong around Dec/Jan (DP-03/04).
    newest_posting = max((t.posting_date for t in transactions), default=None)
    period_start, period_end, corrected = resolve_period_years(
        period_start,
        period_end,
        statement_date=summary_statement_date,
        newest_posting=newest_posting,
    )
    if corrected and period_end is not None:
        warnings.append("EIB: statement period year corrected from the statement/transaction dates")
        statement_month = statement_month_from_date(period_end)
        for tx in transactions:
            tx.statement_month = statement_month

    if not transactions:
        warnings.append("No EIB transaction rows matched expected pattern")

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
