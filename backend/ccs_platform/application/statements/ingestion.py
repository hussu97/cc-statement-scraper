from __future__ import annotations

from datetime import UTC, datetime, time
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.core.settings import PlatformSettings
from ccs_platform.domain.categorization.engine import apply_override_if_exists, categorize, ensure_category
from ccs_platform.domain.statements.identity import checksum_sha256, resolve_statement_identity
from ccs_platform.application.statements.parser_adapter import parse_statement_pdf
from ccs_platform.adapters.storage import StorageAdapter
from ccs_platform.domain.statements.types import ParsedStatement


def _temp_pdf_path(settings: PlatformSettings, profile_key: str, bank_code: str, filename: str) -> Path:
    stamp = datetime.now(UTC).strftime("%Y%m%d%H%M%S")
    safe = filename.replace("/", "_").replace("\\", "_")
    return settings.uploads_temp_dir / profile_key / f"{bank_code}_{stamp}_{safe}"


def _line_count_for_statement(db: Session, statement_id: int) -> int:
    return int(
        db.execute(
            select(func.count(models.StatementLine.id)).where(
                models.StatementLine.statement_id == statement_id
            )
        ).scalar_one()
    )


def ingest_statement_pdf(
    db: Session,
    *,
    settings: PlatformSettings,
    storage: StorageAdapter,
    profile_id: int,
    profile_key: str,
    bank_code: str,
    filename: str,
    content: bytes,
    source: models.SourceType,
    runtime_settings: dict[str, str] | None = None,
) -> dict:
    if not content:
        raise ValueError("Empty PDF content")

    checksum = checksum_sha256(content)
    temp_path = _temp_pdf_path(settings, profile_key, bank_code, filename)
    temp_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path.write_bytes(content)

    try:
        parsed = parse_statement_pdf(bank_code, temp_path, source_filename=filename, runtime_settings=runtime_settings)
    finally:
        temp_path.unlink(missing_ok=True)

    stored_obj = storage.save_pdf(
        content=content,
        filename=filename,
        source=source.value,
        profile_key=profile_key,
    )
    pdf_file = models.PdfFile(
        profile_id=profile_id,
        original_filename=filename,
        checksum_sha256=checksum,
        storage_backend=stored_obj.backend,
        storage_key=stored_obj.key,
        source=source,
    )
    db.add(pdf_file)
    db.flush()

    return ingest_parsed_statement(
        db,
        parsed=parsed,
        profile_id=profile_id,
        pdf_file=pdf_file,
        pdf_checksum_sha256=checksum,
    )


def ingest_parsed_statement(
    db: Session,
    *,
    parsed: ParsedStatement,
    profile_id: int,
    pdf_file: models.PdfFile,
    pdf_checksum_sha256: str,
) -> dict:

    identity = resolve_statement_identity(
        parsed_statement=parsed,
        pdf_checksum_sha256=pdf_checksum_sha256,
    )

    existing = db.execute(
        select(models.Statement).where(
            models.Statement.profile_id == profile_id,
            models.Statement.bank_code == identity.bank_code,
            models.Statement.statement_reference == identity.statement_reference,
            models.Statement.statement_date == identity.statement_date,
        )
    ).scalar_one_or_none()

    old_line_count = 0
    old_statement_id: int | None = None
    if existing:
        old_statement_id = existing.id
        old_line_count = _line_count_for_statement(db, existing.id)
        db.delete(existing)
        db.flush()

    statement = models.Statement(
        profile_id=profile_id,
        bank_code=parsed.bank_code,
        pdf_file_id=pdf_file.id,
        statement_reference=identity.statement_reference,
        statement_reference_raw=parsed.statement_reference_raw,
        reference_source=(
            models.ReferenceSource.EXPLICIT
            if identity.reference_source == "explicit"
            else models.ReferenceSource.FALLBACK
        ),
        statement_date=parsed.statement_date,
        statement_period_start=parsed.statement_period_start,
        statement_period_end=parsed.statement_period_end,
        primary_card_last4=parsed.primary_card_last4,
        card_holder=parsed.card_holder,
        card_type=parsed.card_type,
        warnings_json={"warnings": parsed.warnings} if parsed.warnings else None,
        metadata_json=parsed.metadata,
    )
    db.add(statement)
    db.flush()

    ensure_category(db, "Uncategorized")

    inserted_lines = 0
    for parsed_line in parsed.lines:
        category, _ = categorize(db, merchant_normalized=parsed_line.merchant_normalized)

        tx_time = parsed_line.transaction_time or time(0, 0, 0)
        line = models.StatementLine(
            statement_id=statement.id,
            line_no=parsed_line.line_no,
            transaction_date=parsed_line.transaction_date,
            transaction_time=tx_time,
            is_time_inferred=parsed_line.transaction_time is None,
            posting_date=parsed_line.posting_date,
            merchant_raw=parsed_line.merchant_raw,
            merchant_normalized=parsed_line.merchant_normalized,
            amount_original=parsed_line.amount_original,
            currency_original=parsed_line.currency_original,
            amount_aed=parsed_line.amount_aed,
            direction=(
                models.Direction.CREDIT
                if parsed_line.direction.lower() == "credit"
                else models.Direction.DEBIT
            ),
            transaction_kind=parsed_line.transaction_kind,
            country_code=parsed_line.country_code,
            card_last4=parsed_line.card_last4,
            category=category,
            fingerprint=parsed_line.fingerprint,
            raw_json=parsed_line.raw,
        )
        apply_override_if_exists(db, fingerprint=parsed_line.fingerprint, line=line)
        db.add(line)
        inserted_lines += 1

    db.flush()

    audit_type = "statement_replaced" if old_statement_id else "statement_ingested"
    db.add(
        models.AuditEvent(
            profile_id=profile_id,
            event_type=audit_type,
            entity_type="statement",
            entity_id=str(statement.id),
            payload_json={
                "bank_code": statement.bank_code,
                "statement_reference": statement.statement_reference,
                "statement_date": statement.statement_date.isoformat(),
                "pdf_checksum_sha256": pdf_checksum_sha256,
                "old_statement_id": old_statement_id,
                "old_line_count": old_line_count,
                "new_line_count": inserted_lines,
            },
        )
    )

    return {
        "statement_id": statement.id,
        "statement_reference": statement.statement_reference,
        "statement_date": statement.statement_date.isoformat(),
        "reference_source": statement.reference_source.value,
        "replaced_existing": old_statement_id is not None,
        "old_statement_id": old_statement_id,
        "old_line_count": old_line_count,
        "new_line_count": inserted_lines,
        "pdf_file_id": pdf_file.id,
    }
