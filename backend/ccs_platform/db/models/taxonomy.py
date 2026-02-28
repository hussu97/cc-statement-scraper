from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, DateTime, Enum, Index, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from ccs_platform.db.base import Base
from ccs_platform.db.models.enums import MatchType


class Category(Base):
    __tablename__ = "categories"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False, unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class CategoryRule(Base):
    __tablename__ = "category_rules"
    __table_args__ = (Index("ix_category_rules_priority", "priority"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    category_name: Mapped[str] = mapped_column(String(128), nullable=False)
    match_type: Mapped[MatchType] = mapped_column(Enum(MatchType), nullable=False, default=MatchType.CONTAINS)
    pattern: Mapped[str] = mapped_column(String(512), nullable=False)

    bank_code: Mapped[str | None] = mapped_column(String(16), nullable=True)
    card_last4: Mapped[str | None] = mapped_column(String(4), nullable=True)

    priority: Mapped[int] = mapped_column(Integer, nullable=False, default=100)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )
