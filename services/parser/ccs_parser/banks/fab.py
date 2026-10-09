from __future__ import annotations

import re
from datetime import date
from pathlib import Path

import pdfplumber

from ccs_parser.domain.parsing.models import ParserError, StatementParseResult, TransactionRecord
from ccs_parser.domain.parsing.utils import (
    classify_transaction_kind,
    extract_last4_masked,
    fingerprint_for,
    merchant_normalize,
    parse_amount,
    parse_date,
    statement_month_from_date,
)

BANK_CODE = "FAB"
BANK_NAME = "First Abu Dhabi Bank"

_DATE_RE = re.compile(r"^\d{2}-\d{2}-\d{4}$")
_AMOUNT_RE = re.compile(r"^[\d,]+\.\d{2}$")
# Original-currency amounts are printed in that currency's format (audit DP-07: such
# rows were skipped, so the statement's own debit total exceeded the parsed debits):
#   three decimals for KWD/BHD/OMR ("KWD 18.750"), or a decimal comma ("EUR 108,99").
# The AED Debit/Credit column always uses _AMOUNT_RE.
_THREE_DP_AMOUNT_RE = re.compile(r"^[\d,]+\.\d{3}$")
_DECIMAL_COMMA_AMOUNT_RE = re.compile(r"^\d{1,3}(?:\.\d{3})*,\d{2}$")


def _is_amount(token: str) -> bool:
    return bool(
        _AMOUNT_RE.match(token) or _THREE_DP_AMOUNT_RE.match(token) or _DECIMAL_COMMA_AMOUNT_RE.match(token)
    )


def _normalize_amount(token: str) -> str:
    """"1.234,56" -> "1234.56"; dot-decimal amounts (2 or 3 places) are returned unchanged."""
    if _DECIMAL_COMMA_AMOUNT_RE.match(token):
        return token.replace(".", "").replace(",", ".")
    return token
_CURRENCIES = frozenset(
    "AED USD EUR GBP EGP KES SAR INR JPY CHF CAD AUD QAR BHD KWD OMR"
    " SGD HKD MYR THB ZAR TRY MXN BRL CNY SEK NOK DKK PLN CZK HUF ILS".split()
)

_STATEMENT_DATE_RE = re.compile(
    r"\b(?:[A-Z][A-Z\s]+CARD)\s+(\d{2}-\d{2}-\d{4})\s+(\d{2}-\d{2}-\d{4})\b"
)
_SUPP_CARD_RE = re.compile(r"Supplementary Card\s*:\s*(.+)$")
# "Main Card : 5300 00** **** 9022 CASHBACK CARD": the product printed after the number. The
# header's product cell shares a text line with the address column ("100 SAMPLE TOWER
# CASHBACK CARD 01-09-2026 …"), so this line is the clean source of the card type.
_MAIN_CARD_RE = re.compile(r"Main Card\s*:\s*(.+)$")
_STATEMENT_REF_RE = re.compile(
    r"\b(?:Statement\s*(?:No|Number|Reference|Ref)|Ref(?:erence)?)\b\s*[:#-]?\s*([A-Z0-9\-/]*\d[A-Z0-9\-/]{5,})\b",
    re.IGNORECASE,
)

# Minimum x-coordinate to search for column headers (avoids Arabic/header copies)
_COL_HEADER_X_MIN = 400


def _open_pdf(path: Path, pdf_password: str | None):
    """Context-manager factory that opens a pdfplumber PDF with optional password.

    Tries without a password first (scraper/manual uploads are unencrypted).
    If that raises — indicating an email-sourced encrypted PDF — retries with
    the supplied pdf_password.
    """
    import contextlib

    @contextlib.contextmanager
    def _ctx():
        kwargs: dict = {"password": pdf_password} if pdf_password else {}
        try:
            with pdfplumber.open(str(path)) as pdf:
                yield pdf
        except Exception:  # noqa: BLE001
            if not pdf_password:
                raise ParserError(
                    "PDF_DECRYPT_FAILED",
                    "FAB statement PDF is encrypted. Set FAB_PDF_PASSWORD in runtime settings.",
                )
            try:
                with pdfplumber.open(str(path), **kwargs) as pdf:
                    yield pdf
            except Exception as exc:
                raise ParserError(
                    "PDF_DECRYPT_FAILED",
                    "Unable to decrypt FAB statement PDF. Verify FAB_PDF_PASSWORD.",
                ) from exc

    return _ctx()


def _extract_country_code(description: str) -> str | None:
    tokens = description.split()
    if not tokens:
        return None
    maybe = tokens[-1]
    if len(maybe) == 3 and maybe.isalpha() and maybe.upper() == maybe:
        return maybe
    return None


def _extract_holder_from_line(line: str) -> str | None:
    mr_match = re.search(r"\b(MR|MRS|MS)\s+([A-Z\s]+?)\s+Main Card Product", line)
    if mr_match:
        return f"{mr_match.group(1)} {mr_match.group(2).strip()}"
    if line.replace(" ", "").isalpha() and line.upper() == line and len(line.split()) >= 2:
        return line.strip()
    return None


def _extract_statement_reference(lines: list[str]) -> str | None:
    for line in lines:
        match = _STATEMENT_REF_RE.search(line)
        if match:
            return match.group(1).strip()
    return None


def _get_col_center_x(words: list[dict], col_name: str, x_min: float = _COL_HEADER_X_MIN) -> float | None:
    """Return the center x-coordinate of a named column header word."""
    for w in words:
        if w["text"] == col_name and w["x0"] > x_min:
            return (w["x0"] + w["x1"]) / 2
    return None


def _group_words_into_rows(words: list[dict], y_tolerance: float = 2.0) -> list[list[dict]]:
    """
    Group word dicts by approximate vertical position into rows, returned
    sorted top-to-bottom.  Within each row words are sorted left-to-right.
    """
    rows: list[list[dict]] = []
    for w in sorted(words, key=lambda x: x["top"]):
        placed = False
        for row in rows:
            if abs(row[0]["top"] - w["top"]) <= y_tolerance:
                row.append(w)
                placed = True
                break
        if not placed:
            rows.append([w])
    for row in rows:
        row.sort(key=lambda w: w["x0"])
    return rows


def _parse_txn_row(
    row_words: list[dict],
    debit_x: float | None,
    credit_x: float | None,
) -> dict | None:
    """
    Try to extract a transaction record from a word-row.

    Returns a dict with keys:
        txn_date, posting_date, description, currency,
        amount_original_str, amount_aed_str, is_credit
    or None if the row doesn't match the transaction pattern.
    """
    texts = [w["text"] for w in row_words]

    # Must start with two dates
    if len(texts) < 5:
        return None
    if not _DATE_RE.match(texts[0]) or not _DATE_RE.match(texts[1]):
        return None

    # Locate all amount-shaped tokens
    amount_indices = [i for i, t in enumerate(texts) if _is_amount(t)]
    if len(amount_indices) < 2:
        return None
    # The AED (Debit/Credit column) amount is always dot-decimal.
    if not _AMOUNT_RE.match(texts[amount_indices[-1]]):
        return None

    # The currency token sits immediately before the first amount
    first_amt_idx = amount_indices[0]
    currency_idx = first_amt_idx - 1
    if currency_idx < 2 or texts[currency_idx] not in _CURRENCIES:
        return None

    currency = texts[currency_idx]
    amount_original_str = _normalize_amount(texts[first_amt_idx])
    # Last amount on the row is in either the Debit or Credit column
    last_amt_idx = amount_indices[-1]
    amount_aed_str = texts[last_amt_idx]

    # Description is everything between posting_date and the currency word
    description = " ".join(texts[2:currency_idx]).strip()
    if not description:
        return None

    # ------------------------------------------------------------------
    # Determine Debit vs Credit column from the x-position of last amount
    # ------------------------------------------------------------------
    last_amt_word = row_words[last_amt_idx]
    amt_cx = (last_amt_word["x0"] + last_amt_word["x1"]) / 2

    if debit_x is None and credit_x is None:
        is_credit = False
    elif debit_x is None:
        is_credit = True
    elif credit_x is None:
        is_credit = False
    else:
        is_credit = abs(amt_cx - credit_x) < abs(amt_cx - debit_x)

    return {
        "txn_date": texts[0],
        "posting_date": texts[1],
        "description": description,
        "currency": currency,
        "amount_original_str": amount_original_str,
        "amount_aed_str": amount_aed_str,
        "is_credit": is_credit,
    }


def parse_fab_statement(pdf_path: str | Path, pdf_password: str | None = None) -> StatementParseResult:
    path = Path(pdf_path)

    # ------------------------------------------------------------------
    # Pass 1: text-based extraction for metadata (dates, card numbers,
    # holder names, statement reference).  Column info is not needed here.
    # ------------------------------------------------------------------
    text_lines: list[str] = []
    with _open_pdf(path, pdf_password) as pdf:
        for page in pdf.pages:
            page_lines = [
                ln.strip()
                for ln in (page.extract_text() or "").splitlines()
                if ln.strip()
            ]
            text_lines.extend(page_lines)

    statement_date: date | None = None
    due_date: date | None = None
    main_holder: str | None = None
    main_last4: str | None = None

    current_last4: str | None = None
    current_holder: str | None = None
    current_card_type: str | None = None

    holder_by_last4: dict[str, str] = {}
    card_type_by_last4: dict[str, str] = {}

    for idx, line in enumerate(text_lines):
        holder = _extract_holder_from_line(line)
        if holder and main_holder is None:
            main_holder = holder

        statement_match = _STATEMENT_DATE_RE.search(line)
        if statement_match and statement_date is None:
            statement_date = parse_date(statement_match.group(1), "%d-%m-%Y")
            due_date = parse_date(statement_match.group(2), "%d-%m-%Y")
            card_type_guess = line.split(statement_match.group(1))[0].strip()
            if card_type_guess:
                current_card_type = card_type_guess

        main_card_match = _MAIN_CARD_RE.search(line)
        if main_card_match:
            main_remainder = main_card_match.group(1)
            main_card_last4 = extract_last4_masked(main_remainder)
            main_card_type = main_remainder.split(main_card_last4)[-1].strip() if main_card_last4 else ""
            if main_card_type:
                card_type_by_last4[main_card_last4] = main_card_type
                current_card_type = main_card_type

        supp_match = _SUPP_CARD_RE.search(line)
        if supp_match:
            remainder = supp_match.group(1)
            supp_last4 = extract_last4_masked(remainder)
            if supp_last4:
                current_last4 = supp_last4
                if idx + 1 < len(text_lines):
                    supp_holder = _extract_holder_from_line(text_lines[idx + 1])
                    if supp_holder:
                        current_holder = supp_holder
                        holder_by_last4[supp_last4] = supp_holder
                card_type = remainder.split(supp_last4)[-1].strip()
                if card_type:
                    card_type_by_last4[supp_last4] = card_type
            continue

        masked_last4 = extract_last4_masked(line)
        if masked_last4:
            if main_last4 is None:
                main_last4 = masked_last4
                current_last4 = masked_last4
                if main_holder:
                    holder_by_last4[masked_last4] = main_holder
                if current_card_type:
                    card_type_by_last4[masked_last4] = current_card_type
            if current_last4 is None:
                current_last4 = masked_last4

    # ------------------------------------------------------------------
    # Pass 2: coordinate-aware extraction for transactions.
    # We parse each page's words, determine the Debit/Credit column x
    # positions, then reconstruct each transaction row with the correct
    # debit/credit classification.
    # ------------------------------------------------------------------
    transactions: list[TransactionRecord] = []
    warnings: list[str] = []

    # Track the current card as we encounter card-section headers in order
    page_current_last4: str | None = main_last4
    page_current_holder: str | None = main_holder

    with _open_pdf(path, pdf_password) as pdf:
        for page in pdf.pages:
            words = page.extract_words()
            if not words:
                continue

            debit_x = _get_col_center_x(words, "Debit")
            credit_x = _get_col_center_x(words, "Credit")

            rows = _group_words_into_rows(words)

            for row_words in rows:
                texts = [w["text"] for w in row_words]
                row_text = " ".join(texts)

                # Detect card-section header: "Main Card : ..." or
                # "Supplementary Card : ..."
                supp_match = _SUPP_CARD_RE.search(row_text)
                if supp_match:
                    remainder = supp_match.group(1)
                    last4 = extract_last4_masked(remainder)
                    if last4:
                        page_current_last4 = last4
                        page_current_holder = holder_by_last4.get(last4, main_holder)
                    continue

                masked_last4 = extract_last4_masked(row_text)
                if masked_last4 and not _DATE_RE.match(texts[0]):
                    # Card number row (not a transaction row)
                    if masked_last4 == main_last4:
                        page_current_last4 = masked_last4
                        page_current_holder = main_holder
                    continue

                row_data = _parse_txn_row(row_words, debit_x, credit_x)
                if row_data is None:
                    continue

                transaction_date = parse_date(row_data["txn_date"], "%d-%m-%Y")
                posting_date = parse_date(row_data["posting_date"], "%d-%m-%Y")
                description = row_data["description"]
                currency = row_data["currency"]
                amount_original = parse_amount(row_data["amount_original_str"])
                amount_aed = parse_amount(row_data["amount_aed_str"])

                # Apply debit/credit sign from column position first; then
                # let classify_transaction_kind refine the *kind* label.
                if row_data["is_credit"]:
                    amount_aed = -abs(amount_aed)
                    amount_original = -abs(amount_original)

                merchant_norm = merchant_normalize(description)

                # classify_transaction_kind may further flip amounts for
                # keyword-identified payments/refunds not yet negated.
                kind = classify_transaction_kind(merchant_norm, amount_aed)
                if kind in {"payment", "refund"} and amount_aed > 0:
                    amount_aed = -amount_aed
                    amount_original = -amount_original

                card_last4 = page_current_last4 or main_last4 or "0000"
                card_holder = holder_by_last4.get(card_last4, main_holder)
                card_type = card_type_by_last4.get(card_last4, current_card_type)

                statement_month = (
                    statement_month_from_date(statement_date)
                    if statement_date is not None
                    else statement_month_from_date(posting_date)
                )

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
                        statement_month=statement_month,
                        transaction_date=transaction_date,
                        posting_date=posting_date,
                        merchant_raw=description,
                        merchant_normalized=merchant_norm,
                        country_code=_extract_country_code(description),
                        amount_original=amount_original,
                        currency_original=currency,
                        amount_aed=amount_aed,
                        fx_rate_to_aed=(abs(amount_aed) / abs(amount_original)) if amount_original else None,
                        transaction_kind=kind,
                        source_pdf=str(path),
                        fingerprint=fingerprint,
                    )
                )

    if not transactions:
        warnings.append("No FAB transaction rows matched expected pattern")

    if statement_date is None:
        warnings.append("Statement date not found; statement_month derived from posting dates")
        if transactions:
            fallback_month = statement_month_from_date(
                max(t.posting_date for t in transactions)
            )
            for tx in transactions:
                tx.statement_month = fallback_month
    else:
        if due_date is not None:
            warnings.append(f"Detected due date {due_date.isoformat()}")

    result = StatementParseResult(
        bank_code=BANK_CODE,
        bank_name=BANK_NAME,
        source_pdf=path,
        statement_month=transactions[0].statement_month if transactions else "1970-01",
        transactions=transactions,
        warnings=warnings,
        metadata={
            "main_last4": main_last4,
            "main_holder": main_holder,
            "statement_date": statement_date.isoformat() if statement_date else None,
            "statement_period_end": statement_date.isoformat() if statement_date else None,
            "due_date": due_date.isoformat() if due_date else None,
            "statement_reference": _extract_statement_reference(text_lines),
        },
    )
    return result
