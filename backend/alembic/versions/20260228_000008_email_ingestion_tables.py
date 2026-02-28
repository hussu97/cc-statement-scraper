"""email ingestion tables and service api tokens

Revision ID: 20260228_000008
Revises: 20260228_000007
Create Date: 2026-02-28 00:00:08
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM as PgEnum


revision = "20260228_000008"
down_revision = "20260228_000007"
branch_labels = None
depends_on = None

# PgEnum with create_type=False: SQLAlchemy will NOT emit CREATE TYPE inside
# op.create_table — the _on_table_create hook is a no-op when create_type=False
# on the PostgreSQL-native ENUM type.  On SQLite (CI smoke test) PgEnum renders
# as VARCHAR and the hook skips automatically because the dialect isn't postgres.
# Type creation/deletion is handled explicitly via raw SQL below.
_provider = PgEnum("microsoft", "gmail", name="emailprovider", create_type=False)
_status = PgEnum(
    "queued", "uploaded", "duplicate", "ignored", "failed",
    name="emailingestionstatus",
    create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()

    if bind.dialect.name == "postgresql":
        bind.execute(sa.text(
            "CREATE TYPE IF NOT EXISTS emailprovider AS ENUM ('microsoft', 'gmail')"
        ))
        bind.execute(sa.text(
            "CREATE TYPE IF NOT EXISTS emailingestionstatus"
            " AS ENUM ('queued', 'uploaded', 'duplicate', 'ignored', 'failed')"
        ))

    op.create_table(
        "email_mailboxes",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("profile_id", sa.Integer(), nullable=False),
        sa.Column("provider", _provider, nullable=False),
        sa.Column("mailbox_email", sa.String(length=320), nullable=False),
        sa.Column("display_name", sa.String(length=256), nullable=True),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("sync_state_json", sa.JSON(), nullable=True),
        sa.Column("watch_expiration_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_sync_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error_message", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["profile_id"], ["profiles.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "profile_id",
            "provider",
            "mailbox_email",
            name="uq_email_mailboxes_profile_provider_mailbox",
        ),
    )
    op.create_index("ix_email_mailboxes_profile_id", "email_mailboxes", ["profile_id"], unique=False)
    op.create_index("ix_email_mailboxes_provider", "email_mailboxes", ["provider"], unique=False)

    op.create_table(
        "email_bank_routes",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("profile_id", sa.Integer(), nullable=False),
        sa.Column("bank_code", sa.String(length=16), nullable=False),
        sa.Column("mailbox_id", sa.Integer(), nullable=False),
        sa.Column("sender_allowlist_json", sa.JSON(), nullable=True),
        sa.Column("subject_keywords_json", sa.JSON(), nullable=True),
        sa.Column("attachment_filename_regex", sa.String(length=512), nullable=True),
        sa.Column("gmail_label_filter_json", sa.JSON(), nullable=True),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["profile_id"], ["profiles.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["bank_code"], ["banks.code"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["mailbox_id"], ["email_mailboxes.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("profile_id", "bank_code", name="uq_email_bank_routes_profile_bank"),
    )
    op.create_index("ix_email_bank_routes_profile_id", "email_bank_routes", ["profile_id"], unique=False)
    op.create_index("ix_email_bank_routes_mailbox_id", "email_bank_routes", ["mailbox_id"], unique=False)

    op.create_table(
        "service_api_tokens",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("profile_id", sa.Integer(), nullable=False),
        sa.Column("name", sa.String(length=128), nullable=False),
        sa.Column("token_prefix", sa.String(length=24), nullable=False),
        sa.Column("token_hash", sa.String(length=128), nullable=False),
        sa.Column("scopes_json", sa.JSON(), nullable=True),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["profile_id"], ["profiles.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("profile_id", "name", name="uq_service_api_tokens_profile_name"),
    )
    op.create_index("ix_service_api_tokens_profile_id", "service_api_tokens", ["profile_id"], unique=False)
    op.create_index("ix_service_api_tokens_token_prefix", "service_api_tokens", ["token_prefix"], unique=False)

    op.create_table(
        "email_ingestion_events",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("route_id", sa.Integer(), nullable=False),
        sa.Column("profile_id", sa.Integer(), nullable=False),
        sa.Column("bank_code", sa.String(length=16), nullable=False),
        sa.Column("provider", _provider, nullable=False),
        sa.Column("provider_message_id", sa.String(length=512), nullable=False),
        sa.Column("provider_attachment_id", sa.String(length=512), nullable=False),
        sa.Column("internet_message_id", sa.String(length=512), nullable=True),
        sa.Column("attachment_filename", sa.String(length=512), nullable=False),
        sa.Column("attachment_sha256", sa.String(length=64), nullable=False),
        sa.Column("status", _status, nullable=False, server_default=sa.text("'queued'")),
        sa.Column("upload_job_id", sa.Integer(), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("provider_received_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("processed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("metadata_json", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["route_id"], ["email_bank_routes.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["profile_id"], ["profiles.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["bank_code"], ["banks.code"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["upload_job_id"], ["jobs.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "route_id",
            "provider_message_id",
            "provider_attachment_id",
            name="uq_email_ingestion_events_route_message_attachment",
        ),
        sa.UniqueConstraint(
            "profile_id",
            "bank_code",
            "attachment_sha256",
            name="uq_email_ingestion_events_profile_bank_hash",
        ),
    )
    op.create_index("ix_email_ingestion_events_profile_id", "email_ingestion_events", ["profile_id"], unique=False)
    op.create_index("ix_email_ingestion_events_status", "email_ingestion_events", ["status"], unique=False)
    op.create_index("ix_email_ingestion_events_created_at", "email_ingestion_events", ["created_at"], unique=False)
    op.create_index("ix_email_ingestion_events_upload_job_id", "email_ingestion_events", ["upload_job_id"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_email_ingestion_events_upload_job_id", table_name="email_ingestion_events")
    op.drop_index("ix_email_ingestion_events_created_at", table_name="email_ingestion_events")
    op.drop_index("ix_email_ingestion_events_status", table_name="email_ingestion_events")
    op.drop_index("ix_email_ingestion_events_profile_id", table_name="email_ingestion_events")
    op.drop_table("email_ingestion_events")

    op.drop_index("ix_service_api_tokens_token_prefix", table_name="service_api_tokens")
    op.drop_index("ix_service_api_tokens_profile_id", table_name="service_api_tokens")
    op.drop_table("service_api_tokens")

    op.drop_index("ix_email_bank_routes_mailbox_id", table_name="email_bank_routes")
    op.drop_index("ix_email_bank_routes_profile_id", table_name="email_bank_routes")
    op.drop_table("email_bank_routes")

    op.drop_index("ix_email_mailboxes_provider", table_name="email_mailboxes")
    op.drop_index("ix_email_mailboxes_profile_id", table_name="email_mailboxes")
    op.drop_table("email_mailboxes")

    bind = op.get_bind()
    if bind.dialect.name == "postgresql":
        bind.execute(sa.text("DROP TYPE IF EXISTS emailingestionstatus"))
        bind.execute(sa.text("DROP TYPE IF EXISTS emailprovider"))
