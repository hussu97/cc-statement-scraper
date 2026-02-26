from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from ccs_platform.db.base import Base


class RuntimeSetting(Base):
    __tablename__ = "runtime_settings"
    __table_args__ = (
        UniqueConstraint("profile_id", "key", name="uq_runtime_settings_profile_key"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    profile_id: Mapped[int] = mapped_column(ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False, index=True)
    key: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    value: Mapped[str] = mapped_column(Text, nullable=False, default="")
    bank_code: Mapped[str | None] = mapped_column(String(16), nullable=True)
    is_secret: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    description: Mapped[str | None] = mapped_column(String(512), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )
