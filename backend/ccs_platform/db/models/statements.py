from __future__ import annotations

from datetime import date, datetime, time

from sqlalchemy import (
    JSON,
    Boolean,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ccs_platform.db.base import Base
from ccs_platform.db.models.enums import Direction, ReferenceSource, SourceType, pg_enum


class Bank(Base):
    __tablename__ = "banks"

    code: Mapped[str] = mapped_column(String(16), primary_key=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    supports_historical_month_selection: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    supports_multi_month: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    supports_headless: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    portal_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    statements: Mapped[list[Statement]] = relationship("Statement", back_populates="bank")


class PdfFile(Base):
    __tablename__ = "pdf_files"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    profile_id: Mapped[int] = mapped_column(ForeignKey("profiles.id", ondelete="RESTRICT"), nullable=False, index=True)
    original_filename: Mapped[str] = mapped_column(String(512), nullable=False)
    checksum_sha256: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    storage_backend: Mapped[str] = mapped_column(String(32), nullable=False)
    storage_key: Mapped[str] = mapped_column(String(1024), nullable=False)
    source: Mapped[SourceType] = mapped_column(pg_enum(SourceType), nullable=False)
    uploaded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    profile = relationship("Profile")
    statements: Mapped[list[Statement]] = relationship("Statement", back_populates="pdf_file")


class Statement(Base):
    __tablename__ = "statements"
    __table_args__ = (
        UniqueConstraint(
            "profile_id",
            "bank_code",
            "statement_reference",
            "statement_date",
            name="uq_statement_identity",
        ),
        Index("ix_statements_profile_id", "profile_id"),
        Index("ix_statements_statement_date", "statement_date"),
        Index("ix_statements_reference", "statement_reference"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    profile_id: Mapped[int] = mapped_column(ForeignKey("profiles.id", ondelete="RESTRICT"), nullable=False)
    bank_code: Mapped[str] = mapped_column(ForeignKey("banks.code", ondelete="RESTRICT"), nullable=False)
    pdf_file_id: Mapped[int | None] = mapped_column(ForeignKey("pdf_files.id", ondelete="SET NULL"), nullable=True)

    statement_reference: Mapped[str] = mapped_column(String(256), nullable=False)
    statement_reference_raw: Mapped[str | None] = mapped_column(String(256), nullable=True)
    reference_source: Mapped[ReferenceSource] = mapped_column(pg_enum(ReferenceSource), nullable=False)

    statement_date: Mapped[date] = mapped_column(Date, nullable=False)
    statement_period_start: Mapped[date | None] = mapped_column(Date, nullable=True)
    statement_period_end: Mapped[date | None] = mapped_column(Date, nullable=True)

    primary_card_last4: Mapped[str | None] = mapped_column(String(4), nullable=True)
    card_holder: Mapped[str | None] = mapped_column(String(256), nullable=True)
    card_type: Mapped[str | None] = mapped_column(String(128), nullable=True)

    warnings_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    metadata_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    ingested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    profile = relationship("Profile")
    bank: Mapped[Bank] = relationship("Bank", back_populates="statements")
    pdf_file: Mapped[PdfFile | None] = relationship("PdfFile", back_populates="statements")
    lines: Mapped[list[StatementLine]] = relationship(
        "StatementLine",
        back_populates="statement",
        cascade="all, delete-orphan",
    )


class StatementLine(Base):
    __tablename__ = "statement_lines"
    __table_args__ = (
        Index("ix_statement_lines_transaction_date", "transaction_date"),
        Index("ix_statement_lines_posting_date", "posting_date"),
        Index("ix_statement_lines_merchant_normalized", "merchant_normalized"),
        Index("ix_statement_lines_category", "category"),
        Index("ix_statement_lines_direction", "direction"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    statement_id: Mapped[int] = mapped_column(ForeignKey("statements.id", ondelete="CASCADE"), nullable=False)

    line_no: Mapped[int] = mapped_column(Integer, nullable=False)

    transaction_date: Mapped[date] = mapped_column(Date, nullable=False)
    transaction_time: Mapped[time] = mapped_column(nullable=False, default=time(0, 0, 0))
    is_time_inferred: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    posting_date: Mapped[date | None] = mapped_column(Date, nullable=True)

    merchant_raw: Mapped[str] = mapped_column(Text, nullable=False)
    merchant_normalized: Mapped[str] = mapped_column(String(512), nullable=False)

    amount_original: Mapped[float] = mapped_column(Numeric(14, 2), nullable=False)
    currency_original: Mapped[str] = mapped_column(String(8), nullable=False)
    amount_aed: Mapped[float | None] = mapped_column(Numeric(14, 2), nullable=True)

    direction: Mapped[Direction] = mapped_column(pg_enum(Direction), nullable=False)
    transaction_kind: Mapped[str] = mapped_column(String(64), nullable=False)

    country_code: Mapped[str | None] = mapped_column(String(3), nullable=True)
    card_last4: Mapped[str | None] = mapped_column(String(4), nullable=True)
    category: Mapped[str] = mapped_column(String(128), nullable=False, default="Uncategorized")

    fingerprint: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    raw_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)

    statement: Mapped[Statement] = relationship("Statement", back_populates="lines")
