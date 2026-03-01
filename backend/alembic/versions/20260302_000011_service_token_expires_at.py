"""service_api_tokens: add expires_at column

Revision ID: 20260302_000011
Revises: 20260301_000010
Create Date: 2026-03-02 00:00:11
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260302_000011"
down_revision = "20260301_000010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("service_api_tokens", recreate="auto") as batch_op:
        batch_op.add_column(
            sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True)
        )


def downgrade() -> None:
    with op.batch_alter_table("service_api_tokens", recreate="auto") as batch_op:
        batch_op.drop_column("expires_at")
