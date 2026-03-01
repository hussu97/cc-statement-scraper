"""service_api_tokens: drop profile_id, global unique name constraint

Revision ID: 20260301_000010
Revises: 20260301_000009
Create Date: 2026-03-01 00:00:10
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260301_000010"
down_revision = "20260301_000009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Drop all existing tokens — cannot recover, fresh start
    op.execute(sa.text("DELETE FROM service_api_tokens"))

    # Drop old constraints and index tied to profile_id
    op.drop_index("ix_service_api_tokens_profile_id", table_name="service_api_tokens")
    op.drop_constraint("uq_service_api_tokens_profile_name", "service_api_tokens", type_="unique")
    op.drop_constraint("service_api_tokens_profile_id_fkey", "service_api_tokens", type_="foreignkey")
    op.drop_column("service_api_tokens", "profile_id")

    # New global unique constraint on name
    op.create_unique_constraint("uq_service_api_tokens_name", "service_api_tokens", ["name"])


def downgrade() -> None:
    # Remove new global constraint
    op.drop_constraint("uq_service_api_tokens_name", "service_api_tokens", type_="unique")

    # Re-add profile_id column (nullable — data is not recoverable)
    op.add_column(
        "service_api_tokens",
        sa.Column("profile_id", sa.Integer(), nullable=True),
    )
    op.create_foreign_key(
        "service_api_tokens_profile_id_fkey",
        "service_api_tokens",
        "profiles",
        ["profile_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.create_index("ix_service_api_tokens_profile_id", "service_api_tokens", ["profile_id"], unique=False)
    op.create_unique_constraint(
        "uq_service_api_tokens_profile_name",
        "service_api_tokens",
        ["profile_id", "name"],
    )
