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

    # recreate="always" forces copy-and-move on every dialect (required for
    # SQLite, which has no ALTER TABLE … DROP CONSTRAINT / DROP COLUMN).
    # Dropping profile_id automatically removes the FK, the profile_id index,
    # and the (profile_id, name) unique constraint in the recreated table.
    with op.batch_alter_table("service_api_tokens", recreate="always") as batch_op:
        batch_op.drop_index("ix_service_api_tokens_profile_id")
        batch_op.drop_column("profile_id")
        batch_op.create_unique_constraint("uq_service_api_tokens_name", ["name"])


def downgrade() -> None:
    with op.batch_alter_table("service_api_tokens", recreate="always") as batch_op:
        batch_op.drop_constraint("uq_service_api_tokens_name", type_="unique")
        batch_op.add_column(sa.Column("profile_id", sa.Integer(), nullable=True))
        batch_op.create_foreign_key(
            "service_api_tokens_profile_id_fkey",
            "profiles",
            ["profile_id"],
            ["id"],
            ondelete="CASCADE",
        )
        batch_op.create_index("ix_service_api_tokens_profile_id", ["profile_id"], unique=False)
        batch_op.create_unique_constraint(
            "uq_service_api_tokens_profile_name",
            ["profile_id", "name"],
        )
