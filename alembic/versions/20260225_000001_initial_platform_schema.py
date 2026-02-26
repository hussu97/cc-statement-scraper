"""initial platform schema

Revision ID: 20260225_000001
Revises: 
Create Date: 2026-02-25 00:00:01
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260225_000001"
down_revision = None
branch_labels = None
depends_on = None


def _initial_metadata() -> sa.MetaData:
    metadata = sa.MetaData()

    source_type_enum = sa.Enum("scrape", "upload", name="sourcetype")
    reference_source_enum = sa.Enum("explicit", "fallback", name="referencesource")
    match_type_enum = sa.Enum("contains", "exact", "regex", name="matchtype")
    job_status_enum = sa.Enum("queued", "running", "succeeded", "failed", "cancelled", name="jobstatus")
    job_type_enum = sa.Enum(
        "scrape",
        "upload",
        "reclassify",
        "export_workbook",
        "parser_validate",
        "bank_connection_test",
        "reparse_statement",
        name="jobtype",
    )
    direction_enum = sa.Enum("debit", "credit", name="direction")
    schedule_status_enum = sa.Enum("active", "paused", name="schedulestatus")
    export_status_enum = sa.Enum("queued", "ready", "failed", name="exportstatus")

    banks = sa.Table(
        "banks",
        metadata,
        sa.Column("code", sa.String(length=16), nullable=False),
        sa.Column("name", sa.String(length=128), nullable=False),
        sa.Column("supports_historical_month_selection", sa.Boolean(), nullable=False),
        sa.Column("supports_multi_month", sa.Boolean(), nullable=False),
        sa.Column("supports_headless", sa.Boolean(), nullable=False),
        sa.Column("portal_url", sa.String(length=512), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("code"),
    )

    pdf_files = sa.Table(
        "pdf_files",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("original_filename", sa.String(length=512), nullable=False),
        sa.Column("checksum_sha256", sa.String(length=64), nullable=False),
        sa.Column("storage_backend", sa.String(length=32), nullable=False),
        sa.Column("storage_key", sa.String(length=1024), nullable=False),
        sa.Column("source", source_type_enum, nullable=False),
        sa.Column("uploaded_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    sa.Index("ix_pdf_files_checksum_sha256", pdf_files.c.checksum_sha256)

    statements = sa.Table(
        "statements",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("bank_code", sa.String(length=16), nullable=False),
        sa.Column("pdf_file_id", sa.Integer(), nullable=True),
        sa.Column("statement_reference", sa.String(length=256), nullable=False),
        sa.Column("statement_reference_raw", sa.String(length=256), nullable=True),
        sa.Column("reference_source", reference_source_enum, nullable=False),
        sa.Column("statement_date", sa.Date(), nullable=False),
        sa.Column("statement_period_start", sa.Date(), nullable=True),
        sa.Column("statement_period_end", sa.Date(), nullable=True),
        sa.Column("primary_card_last4", sa.String(length=4), nullable=True),
        sa.Column("card_holder", sa.String(length=256), nullable=True),
        sa.Column("card_type", sa.String(length=128), nullable=True),
        sa.Column("warnings_json", sa.JSON(), nullable=True),
        sa.Column("metadata_json", sa.JSON(), nullable=True),
        sa.Column("ingested_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["bank_code"], ["banks.code"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["pdf_file_id"], ["pdf_files.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("bank_code", "statement_reference", "statement_date", name="uq_statement_identity"),
    )
    sa.Index("ix_statements_statement_date", statements.c.statement_date)
    sa.Index("ix_statements_reference", statements.c.statement_reference)

    statement_lines = sa.Table(
        "statement_lines",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("statement_id", sa.Integer(), nullable=False),
        sa.Column("line_no", sa.Integer(), nullable=False),
        sa.Column("transaction_date", sa.Date(), nullable=False),
        sa.Column("transaction_time", sa.Time(), nullable=False),
        sa.Column("is_time_inferred", sa.Boolean(), nullable=False),
        sa.Column("posting_date", sa.Date(), nullable=True),
        sa.Column("merchant_raw", sa.Text(), nullable=False),
        sa.Column("merchant_normalized", sa.String(length=512), nullable=False),
        sa.Column("amount_original", sa.Numeric(precision=14, scale=2), nullable=False),
        sa.Column("currency_original", sa.String(length=8), nullable=False),
        sa.Column("amount_aed", sa.Numeric(precision=14, scale=2), nullable=True),
        sa.Column("direction", direction_enum, nullable=False),
        sa.Column("transaction_kind", sa.String(length=64), nullable=False),
        sa.Column("country_code", sa.String(length=3), nullable=True),
        sa.Column("card_last4", sa.String(length=4), nullable=True),
        sa.Column("category", sa.String(length=128), nullable=False),
        sa.Column("fingerprint", sa.String(length=64), nullable=True),
        sa.Column("raw_json", sa.JSON(), nullable=True),
        sa.ForeignKeyConstraint(["statement_id"], ["statements.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    sa.Index("ix_statement_lines_transaction_date", statement_lines.c.transaction_date)
    sa.Index("ix_statement_lines_posting_date", statement_lines.c.posting_date)
    sa.Index("ix_statement_lines_merchant_normalized", statement_lines.c.merchant_normalized)
    sa.Index("ix_statement_lines_category", statement_lines.c.category)
    sa.Index("ix_statement_lines_direction", statement_lines.c.direction)
    sa.Index("ix_statement_lines_fingerprint", statement_lines.c.fingerprint)

    sa.Table(
        "categories",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("name", sa.String(length=128), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("name"),
    )

    category_rules = sa.Table(
        "category_rules",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("name", sa.String(length=128), nullable=False),
        sa.Column("category_name", sa.String(length=128), nullable=False),
        sa.Column("match_type", match_type_enum, nullable=False),
        sa.Column("pattern", sa.String(length=512), nullable=False),
        sa.Column("bank_code", sa.String(length=16), nullable=True),
        sa.Column("card_last4", sa.String(length=4), nullable=True),
        sa.Column("priority", sa.Integer(), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    sa.Index("ix_category_rules_priority", category_rules.c.priority)

    jobs = sa.Table(
        "jobs",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("job_type", job_type_enum, nullable=False),
        sa.Column("status", job_status_enum, nullable=False),
        sa.Column("payload_json", sa.JSON(), nullable=True),
        sa.Column("result_json", sa.JSON(), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("progress_percent", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    sa.Index("ix_jobs_status", jobs.c.status)
    sa.Index("ix_jobs_job_type", jobs.c.job_type)
    sa.Index("ix_jobs_created_at", jobs.c.created_at)

    job_items = sa.Table(
        "job_items",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("job_id", sa.Integer(), nullable=False),
        sa.Column("bank_code", sa.String(length=16), nullable=True),
        sa.Column("target_month", sa.String(length=16), nullable=True),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("message", sa.Text(), nullable=True),
        sa.Column("metadata_json", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["job_id"], ["jobs.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    sa.Index("ix_job_items_status", job_items.c.status)
    sa.Index("ix_job_items_bank_month", job_items.c.bank_code, job_items.c.target_month)

    schedules = sa.Table(
        "schedules",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("name", sa.String(length=128), nullable=False),
        sa.Column("job_type", job_type_enum, nullable=False),
        sa.Column("payload_json", sa.JSON(), nullable=True),
        sa.Column("rrule", sa.String(length=256), nullable=False),
        sa.Column("timezone", sa.String(length=64), nullable=False),
        sa.Column("status", schedule_status_enum, nullable=False),
        sa.Column("next_run_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_run_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    sa.Index("ix_schedules_next_run", schedules.c.next_run_at)

    sa.Table(
        "exports",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("export_type", sa.String(length=64), nullable=False),
        sa.Column("status", export_status_enum, nullable=False),
        sa.Column("job_id", sa.Integer(), nullable=True),
        sa.Column("storage_backend", sa.String(length=32), nullable=True),
        sa.Column("storage_key", sa.String(length=1024), nullable=True),
        sa.Column("filename", sa.String(length=512), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("ready_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["job_id"], ["jobs.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )

    audit_events = sa.Table(
        "audit_events",
        metadata,
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("event_type", sa.String(length=128), nullable=False),
        sa.Column("entity_type", sa.String(length=64), nullable=False),
        sa.Column("entity_id", sa.String(length=64), nullable=False),
        sa.Column("payload_json", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    sa.Index("ix_audit_events_created", audit_events.c.created_at)

    return metadata


def upgrade() -> None:
    metadata = _initial_metadata()
    bind = op.get_bind()
    metadata.create_all(bind=bind)


def downgrade() -> None:
    metadata = _initial_metadata()
    bind = op.get_bind()
    metadata.drop_all(bind=bind)
