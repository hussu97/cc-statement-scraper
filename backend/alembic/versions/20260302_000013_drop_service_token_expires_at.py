"""service_api_tokens: drop expires_at column

Revision ID: 20260302_000013
Revises: 20260302_000012
Create Date: 2026-03-02 00:00:13
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260302_000013"
down_revision = "20260302_000012"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("service_api_tokens", recreate="auto") as batch_op:
        batch_op.drop_column("expires_at")


def downgrade() -> None:
    with op.batch_alter_table("service_api_tokens", recreate="auto") as batch_op:
        batch_op.add_column(
            sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True)
        )
