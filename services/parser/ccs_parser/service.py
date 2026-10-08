"""Parse a local PDF into a parse-v1 contract response (no HTTP, no I/O beyond the file)."""

from __future__ import annotations

import hashlib
import logging
import re
from datetime import date
from decimal import Decimal
from pathlib import Path
from typing import Any

from pydantic import ValidationError

from ccs_parser import CONTRACT_VERSION, PARSER_VERSION, PASSWORD_SETTING_KEYS, SUPPORTED_BANKS
from ccs_parser.contract import ParseResponse
from ccs_parser.countries import normalize_country_code
from ccs_parser.detection import detect_bank_code
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.domain.statements.identity import resolve_statement_identity
from ccs_parser.domain.statements.types import ParsedLine, ParsedStatement
from ccs_parser.kinds import map_kind
from ccs_parser.limits import check_document_limits
from ccs_parser.parser_adapter import parse_statement_pdf
from ccs_parser.totals import TOTAL_KEYS, TotalsResult, extract_totals, read_text_lines

logger = logging.getLogger(__name__)

_UNKNOWN_CARD = "0000"
_LAST4_RE = re.compile(r"[0-9]{4}")
_HISTORY_PDF_TYPE = "transaction_history"
_FX_PLACES = Decimal("1e-8")
# Totals that keep their sign; every other money value is absolute.
SIGNED_TOTAL_KEYS = frozenset({"opening_balance", "closing_balance"})
# Metadata keys that only made sense inside the legacy backend.
_DROPPED_METADATA_KEYS = {"source_pdf"}


# ---------------------------------------------------------------- formatting


def money(value: float | Decimal) -> str:
    """Absolute decimal string with two places.

    Legacy parsers hold amounts as floats parsed from 2-dp strings, so formatting
    with ``.2f`` reproduces the printed value exactly.
    """
    return f"{abs(Decimal(f'{value:.2f}')):.2f}"


def signed_money(value: Decimal) -> str:
    """Signed two-place string (balances: negative = card in credit). Never "-0.00"."""
    quantized = Decimal(f"{value:.2f}")
    return "0.00" if quantized == 0 else f"{quantized:.2f}"


def money_or_none(value: float | Decimal | None) -> str | None:
    return None if value is None else money(value)


def fx_rate(value: float | None, currency: str | None = None) -> str | None:
    """AED per unit of ``currency`` as numeric(18,8), or None.

    An AED line is always "1" whatever the bank printed (X-33: some parsers gave 1, some
    null). A rate that rounds to zero at 8 places can't be stored (the DB requires
    fx_rate > 0), so it is reported as unknown rather than failing the parse.
    """
    if currency == "AED":
        return "1"
    if value is None:
        return None
    dec = Decimal(repr(abs(float(value))))
    if dec.as_tuple().exponent < -8:  # type: ignore[operator]
        dec = dec.quantize(_FX_PLACES)
    if dec == 0:
        return None
    return format(dec.normalize(), "f")


def _iso(value: date | None) -> str | None:
    return value.isoformat() if value is not None else None


def _card(value: str | None) -> str | None:
    """A 4-digit card suffix, or None (unknown, placeholder or malformed: the DB requires ^[0-9]{4}$)."""
    token = (value or "").strip()
    if token == _UNKNOWN_CARD or not _LAST4_RE.fullmatch(token):
        return None
    return token


def _validation_summary(exc: ValidationError) -> str:
    """Where the output broke the contract, without echoing values (they are statement data)."""
    parts: list[str] = []
    for err in exc.errors()[:5]:
        loc = ".".join(str(p) for p in err.get("loc", ()))
        if err.get("type") == "value_error" and not loc.endswith(("_date", "_time", "period_start", "period_end")):
            detail = str(err.get("msg", "")).removeprefix("Value error, ")
        else:
            detail = str(err.get("type", "invalid"))
        parts.append(f"{loc or 'response'}: {detail}")
    more = exc.error_count() - len(parts)
    return "; ".join(parts) + (f" (+{more} more)" if more > 0 else "")


# ---------------------------------------------------------------- PDF state


def pdf_open_state(pdf_path: Path, passwords: list[str | None]) -> str:
    """'ok' | 'encrypted' (no candidate password works) | 'corrupt'."""
    try:
        from pypdf import PdfReader  # noqa: PLC0415

        reader = PdfReader(str(pdf_path))
        if not reader.is_encrypted:
            return "ok"
        for password in ["", *[p for p in passwords if p]]:
            try:
                if reader.decrypt(password):
                    return "ok"
            except Exception:  # noqa: BLE001
                continue
        return "encrypted"
    except Exception:  # noqa: BLE001
        return "corrupt"


def _is_pdf_library_error(exc: BaseException) -> bool:
    module = type(exc).__module__ or ""
    return module.startswith(("pdfminer", "pdfplumber", "pypdf"))


# ---------------------------------------------------------------- building


def _line_out(line: ParsedLine) -> dict[str, Any]:
    if line.fingerprint is None:
        raise ValueError("legacy parser produced a line without a fingerprint")
    return {
        "line_no": line.line_no,
        "txn_date": _iso(line.transaction_date),
        "txn_time": line.transaction_time.isoformat() if line.transaction_time else None,
        "posting_date": _iso(line.posting_date),
        "description_raw": line.merchant_raw,
        "merchant_normalized": line.merchant_normalized,
        "amount_original": money(line.amount_original),
        "currency_original": line.currency_original,
        "amount_aed": money_or_none(line.amount_aed),
        "fx_rate": fx_rate(line.fx_rate_to_aed, line.currency_original),
        "direction": line.direction,
        "kind": map_kind(line.transaction_kind, line.merchant_normalized, line.direction),
        "country_code": normalize_country_code(line.country_code),
        "card_last4": _card(line.card_last4),
        "card_holder": line.card_holder,
        "legacy_fingerprint": line.fingerprint,
    }


def _statement_out(
    st: ParsedStatement,
    *,
    pdf_sha256: str,
    totals: TotalsResult | None,
) -> dict[str, Any]:
    identity = resolve_statement_identity(parsed_statement=st, pdf_checksum_sha256=pdf_sha256)
    is_history = (st.metadata or {}).get("pdf_type") == _HISTORY_PDF_TYPE

    metadata = {k: v for k, v in (st.metadata or {}).items() if k not in _DROPPED_METADATA_KEYS}
    metadata["pdf_sha256"] = pdf_sha256

    warnings = list(st.warnings)
    totals_out: dict[str, str | None] = dict.fromkeys(TOTAL_KEYS)
    due_date = (st.metadata or {}).get("due_date") or None
    if totals is not None and not is_history:
        warnings.extend(totals.warnings)
        for key in TOTAL_KEYS:
            value = totals.values.get(key)
            if value is None:
                continue
            totals_out[key] = signed_money(value) if key in SIGNED_TOTAL_KEYS else money(value)
        if due_date is None and totals.due_date is not None:
            due_date = totals.due_date.isoformat()

    return {
        "kind": "history_extract" if is_history else "statement",
        "bank_code": st.bank_code,
        "statement_reference": identity.statement_reference,
        "reference_source": identity.reference_source,
        "statement_date": _iso(identity.statement_date),
        "period_start": _iso(st.statement_period_start),
        "period_end": _iso(st.statement_period_end),
        "due_date": due_date,
        "primary_card_last4": _card(st.primary_card_last4),
        "card_holder": st.card_holder,
        "card_type": st.card_type,
        "totals": totals_out,
        "warnings": warnings,
        "metadata": metadata,
        "lines": [_line_out(line) for line in st.lines],
    }


def _clean_settings(settings: dict[str, Any] | None) -> dict[str, str]:
    return {str(k): str(v) for k, v in (settings or {}).items() if v not in (None, "")}


# A wrong bank hint makes the hinted parser fail (or find nothing) on a PDF it can't read.
# These failures are worth one detection pass before failing permanently (SRV-17).
_HINT_RETRY_CODES = frozenset({"UNSUPPORTED_LAYOUT", "PDF_DECRYPT_FAILED", "PARSE_OUTPUT_INVALID"})


def _detect_or_fail(pdf_path: Path, passwords: list[str | None]) -> str:
    detected = detect_bank_code(pdf_path, extra_passwords=passwords)
    if detected:
        return detected.upper().strip()
    state = pdf_open_state(pdf_path, passwords)
    if state == "encrypted":
        raise ParserError("PDF_DECRYPT_FAILED", "PDF is encrypted and none of the supplied passwords opened it.")
    if state == "corrupt":
        raise ParserError("UNSUPPORTED_LAYOUT", "File could not be read as a PDF.")
    raise ParserError("BANK_UNDETECTED", "Could not infer the bank from the PDF content.")


def _parse_as(
    bank_code: str,
    pdf_path: Path,
    *,
    filename: str | None,
    runtime_settings: dict[str, str],
    passwords: list[str | None],
    pdf_sha256: str,
    extra_warnings: list[str],
) -> dict[str, Any]:
    """Parse ``pdf_path`` as ``bank_code`` and return the validated contract response."""
    try:
        parsed = parse_statement_pdf(
            bank_code,
            pdf_path,
            source_filename=filename,
            runtime_settings=runtime_settings,
        )
    except ParserError:
        raise
    except Exception as exc:
        state = pdf_open_state(pdf_path, passwords)
        if state == "encrypted":
            raise ParserError("PDF_DECRYPT_FAILED", f"{bank_code}: unable to decrypt PDF with the supplied passwords.")
        if state == "corrupt" or _is_pdf_library_error(exc):
            raise ParserError("UNSUPPORTED_LAYOUT", f"{bank_code}: PDF could not be read ({type(exc).__name__}).")
        raise

    statements = parsed if isinstance(parsed, list) else [parsed]
    if not statements:
        raise ParserError("UNSUPPORTED_LAYOUT", f"{bank_code}: parser returned no statements.")

    is_history = any((st.metadata or {}).get("pdf_type") == _HISTORY_PDF_TYPE for st in statements)
    totals: TotalsResult | None = None
    if not is_history:
        totals = extract_totals(bank_code, read_text_lines(pdf_path, passwords))

    response = {
        "contract_version": CONTRACT_VERSION,
        "parser_version": PARSER_VERSION,
        "bank_code": bank_code,
        "document_kind": "history_pdf" if is_history else "statement_pdf",
        "statements": [_statement_out(st, pdf_sha256=pdf_sha256, totals=totals) for st in statements],
    }
    for st in response["statements"]:
        st["warnings"] = [*extra_warnings, *st["warnings"]]
    # Validate against the contract (which mirrors the DB constraints). The same PDF
    # always produces the same output, so a violation is permanent, not a retryable 5xx.
    try:
        return ParseResponse.model_validate(response).model_dump(mode="json")
    except ValidationError as exc:
        summary = _validation_summary(exc)
        logger.warning("parser output failed contract validation | bank=%s | %s", bank_code, summary)
        raise ParserError("PARSE_OUTPUT_INVALID", f"{bank_code}: parser output is invalid ({summary}).") from exc


def _has_no_lines(response: dict[str, Any]) -> bool:
    return all(not st["lines"] for st in response["statements"])


def parse_document(
    pdf_path: Path,
    *,
    filename: str | None = None,
    bank_code_hint: str | None = None,
    settings: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Parse ``pdf_path`` and return a validated parse-v1 response dict.

    Raises ``ParserError`` for permanent, classified failures; anything else is a bug
    or a transient failure and should surface as a 5xx.

    With a ``bank_code_hint`` the hinted parser runs first and the bank is also detected
    from the PDF (SRV-17). If the hinted parse fails with a layout, decryption or output
    error, or finds no lines at all, and detection names a different bank, the parse is
    retried once as that bank and every statement carries a warning. A hinted parse that
    did find lines stands, with a warning when detection disagrees.
    """
    pdf_path = Path(pdf_path)
    runtime_settings = _clean_settings(settings)
    passwords: list[str | None] = [runtime_settings.get(key) for key in PASSWORD_SETTING_KEYS]
    check_document_limits(pdf_path, passwords)
    pdf_sha256 = hashlib.sha256(pdf_path.read_bytes()).hexdigest()

    def parse_as(bank_code: str, extra_warnings: list[str] | None = None) -> dict[str, Any]:
        return _parse_as(
            bank_code,
            pdf_path,
            filename=filename,
            runtime_settings=runtime_settings,
            passwords=passwords,
            pdf_sha256=pdf_sha256,
            extra_warnings=extra_warnings or [],
        )

    hint = (bank_code_hint or "").strip().upper() or None
    if hint is None:
        return parse_as(_detect_or_fail(pdf_path, passwords))
    if hint not in SUPPORTED_BANKS:
        raise ParserError("UNSUPPORTED_BANK", f"Unsupported bank code: {hint}")

    hinted: dict[str, Any] | None = None
    hint_error: ParserError | None = None
    try:
        hinted = parse_as(hint)
    except ParserError as exc:
        if exc.code not in _HINT_RETRY_CODES:
            raise
        hint_error = exc

    detected = (detect_bank_code(pdf_path, extra_passwords=passwords) or "").upper().strip()
    if detected not in SUPPORTED_BANKS or detected == hint:
        detected = ""

    if hinted is not None and not _has_no_lines(hinted):
        if detected:
            # The hinted parser read the PDF, so the hint wins (it is the route's or the
            # user's explicit choice, and ENBD/EIB share a template detection can confuse),
            # but say so: a permissive parser can read another bank's rows.
            logger.warning("bank_code_hint disagrees with detection | hint=%s | detected=%s", hint, detected)
            note = f"This PDF looks like {detected}, not {hint}; parsed as {hint} because of the bank hint"
            for st in hinted["statements"]:
                st["warnings"].insert(0, note)
        return hinted

    def hinted_outcome() -> dict[str, Any]:
        if hinted is not None:
            return hinted
        assert hint_error is not None
        raise hint_error

    if not detected:
        return hinted_outcome()

    logger.warning("bank_code_hint did not match the PDF | hint=%s | detected=%s", hint, detected)
    warning = f"Bank hint {hint} did not match this PDF; parsed as {detected} (detected from the PDF)"
    try:
        retried = parse_as(detected, [warning])
    except ParserError:
        return hinted_outcome()
    if hinted is not None and _has_no_lines(retried):
        return hinted
    return retried
