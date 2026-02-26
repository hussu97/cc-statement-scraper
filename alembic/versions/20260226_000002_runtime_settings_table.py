"""runtime settings table

Revision ID: 20260226_000002
Revises: 20260225_000001
Create Date: 2026-02-26 00:00:02
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260226_000002"
down_revision = "20260225_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "runtime_settings",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("key", sa.String(length=128), nullable=False),
        sa.Column("value", sa.Text(), nullable=False),
        sa.Column("bank_code", sa.String(length=16), nullable=True),
        sa.Column("is_secret", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("description", sa.String(length=512), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("key"),
    )
    op.create_index("ix_runtime_settings_key", "runtime_settings", ["key"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_runtime_settings_key", table_name="runtime_settings")
    op.drop_table("runtime_settings")
