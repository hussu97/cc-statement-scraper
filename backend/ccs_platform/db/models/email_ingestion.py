from __future__ import annotations

from datetime import datetime

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from ccs_platform.db.base import Base
from ccs_platform.db.models.enums import EmailIngestionStatus, EmailProvider, pg_enum


class EmailMailbox(Base):
    __tablename__ = "email_mailboxes"
    __table_args__ = (
        UniqueConstraint(
            "profile_id",
            "provider",
            "mailbox_email",
            name="uq_email_mailboxes_profile_provider_mailbox",
        ),
        Index("ix_email_mailboxes_profile_id", "profile_id"),
        Index("ix_email_mailboxes_provider", "provider"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    profile_id: Mapped[int] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False)
    provider: Mapped[EmailProvider] = mapped_column(pg_enum(EmailProvider), nullable=False)
    mailbox_email: Mapped[str] = mapped_column(String(320), nullable=False)
    display_name: Mapped[str | None] = mapped_column(String(256), nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    sync_state_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    watch_expiration_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_sync_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_error_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_error_message: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class EmailBankRoute(Base):
    __tablename__ = "email_bank_routes"
    __table_args__ = (
        UniqueConstraint("profile_id", "bank_code", name="uq_email_bank_routes_profile_bank"),
        Index("ix_email_bank_routes_profile_id", "profile_id"),
        Index("ix_email_bank_routes_mailbox_id", "mailbox_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    profile_id: Mapped[int] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False)
    bank_code: Mapped[str] = mapped_column(ForeignKey("banks.code", ondelete="CASCADE"), nullable=False)
    mailbox_id: Mapped[int] = mapped_column(ForeignKey("email_mailboxes.id", ondelete="CASCADE"), nullable=False)

    sender_allowlist_json: Mapped[list[str] | None] = mapped_column(JSON, nullable=True)
    subject_keywords_json: Mapped[list[str] | None] = mapped_column(JSON, nullable=True)
    attachment_filename_regex: Mapped[str | None] = mapped_column(String(512), nullable=True)
    gmail_label_filter_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class EmailIngestionEvent(Base):
    __tablename__ = "email_ingestion_events"
    __table_args__ = (
        UniqueConstraint(
            "route_id",
            "provider_message_id",
            "provider_attachment_id",
            name="uq_email_ingestion_events_route_message_attachment",
        ),
        UniqueConstraint(
            "profile_id",
            "bank_code",
            "attachment_sha256",
            name="uq_email_ingestion_events_profile_bank_hash",
        ),
        Index("ix_email_ingestion_events_profile_id", "profile_id"),
        Index("ix_email_ingestion_events_status", "status"),
        Index("ix_email_ingestion_events_created_at", "created_at"),
        Index("ix_email_ingestion_events_upload_job_id", "upload_job_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    route_id: Mapped[int] = mapped_column(ForeignKey("email_bank_routes.id", ondelete="RESTRICT"), nullable=False)
    profile_id: Mapped[int] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False)
    bank_code: Mapped[str] = mapped_column(ForeignKey("banks.code", ondelete="CASCADE"), nullable=False)
    provider: Mapped[EmailProvider] = mapped_column(pg_enum(EmailProvider), nullable=False)
    provider_message_id: Mapped[str] = mapped_column(String(512), nullable=False)
    provider_attachment_id: Mapped[str] = mapped_column(String(512), nullable=False)
    internet_message_id: Mapped[str | None] = mapped_column(String(512), nullable=True)
    attachment_filename: Mapped[str] = mapped_column(String(512), nullable=False)
    attachment_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[EmailIngestionStatus] = mapped_column(
        pg_enum(EmailIngestionStatus),
        nullable=False,
        default=EmailIngestionStatus.QUEUED,
    )
    upload_job_id: Mapped[int | None] = mapped_column(ForeignKey("jobs.id", ondelete="SET NULL"), nullable=True)
    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    provider_received_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    processed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    metadata_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class ServiceApiToken(Base):
    __tablename__ = "service_api_tokens"
    __table_args__ = (
        UniqueConstraint("name", name="uq_service_api_tokens_name"),
        Index("ix_service_api_tokens_token_prefix", "token_prefix"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    token_prefix: Mapped[str] = mapped_column(String(24), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    scopes_json: Mapped[list[str] | None] = mapped_column(JSON, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
