from __future__ import annotations

import hashlib
from datetime import date, datetime

from ccs_platform.domain.statements.types import ParsedStatement, StatementIdentity


_GENERIC_REFERENCE_TOKENS = {
    "REFERENCE",
    "ERENCE",
    "REF",
    "STATEMENTREFERENCE",
    "STATEMENTREF",
    "STATEMENTNUMBER",
    "STATEMENTNO",
}


def _clean_reference(value: str) -> str:
    cleaned = "".join(ch for ch in value.strip().upper() if ch.isalnum() or ch in {"-", "/", "_"})
    return cleaned[:256]


def _is_timestamp_like_reference(value: str) -> bool:
    digits = "".join(ch for ch in value if ch.isdigit())
    if len(digits) != len(value) or len(digits) != 14:
        return False
    try:
        parsed = datetime.strptime(digits, "%Y%m%d%H%M%S")
    except ValueError:
        return False
    return 2000 <= parsed.year <= 2100


def _is_low_quality_reference(value: str) -> bool:
    compact = "".join(ch for ch in value if ch.isalnum())
    if not compact:
        return True
    if compact in _GENERIC_REFERENCE_TOKENS:
        return True
    if _is_timestamp_like_reference(compact):
        return True
    return False


def resolve_statement_identity(
    *,
    parsed_statement: ParsedStatement,
    pdf_checksum_sha256: str,
) -> StatementIdentity:
    raw_ref = (parsed_statement.statement_reference_raw or "").strip()
    cleaned_ref = _clean_reference(raw_ref) if raw_ref else ""
    if cleaned_ref and not _is_low_quality_reference(cleaned_ref):
        return StatementIdentity(
            bank_code=parsed_statement.bank_code,
            statement_reference=cleaned_ref,
            statement_date=parsed_statement.statement_date,
            reference_source="explicit",
        )

    card_tokens = sorted(
        {
            line.card_last4.strip()
            for line in parsed_statement.lines
            if line.card_last4 and len(line.card_last4.strip()) == 4
        }
    )

    if card_tokens:
        joined = "-".join(card_tokens)
        ref = f"AUTO-{parsed_statement.bank_code}-{parsed_statement.statement_date.isoformat()}-{joined}"
    else:
        ref = (
            f"AUTO-{parsed_statement.bank_code}-{parsed_statement.statement_date.isoformat()}-"
            f"{pdf_checksum_sha256[:12]}"
        )

    return StatementIdentity(
        bank_code=parsed_statement.bank_code,
        statement_reference=_clean_reference(ref),
        statement_date=parsed_statement.statement_date,
        reference_source="fallback",
    )


def checksum_sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()
