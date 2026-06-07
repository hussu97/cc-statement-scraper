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


def _valid_card_token(value: str | None) -> str | None:
    token = (value or "").strip()
    if len(token) != 4 or not token.isdigit() or token == "0000":
        return None
    return token


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
            token
            for line in parsed_statement.lines
            if (token := _valid_card_token(line.card_last4)) is not None
        }
    )
    primary_card_token = _valid_card_token(parsed_statement.primary_card_last4)
    if primary_card_token is not None:
        card_tokens = sorted({*card_tokens, primary_card_token})

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
