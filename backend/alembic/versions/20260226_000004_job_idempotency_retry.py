"""job idempotency and retry metadata

Revision ID: 20260226_000004
Revises: 20260226_000003
Create Date: 2026-02-26 00:00:04
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260226_000004"
down_revision = "20260226_000003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("jobs") as batch_op:
        batch_op.add_column(sa.Column("idempotency_key", sa.String(length=128), nullable=True))
        batch_op.add_column(
            sa.Column(
                "attempt_count",
                sa.Integer(),
                nullable=False,
                server_default=sa.text("0"),
            )
        )
        batch_op.add_column(
            sa.Column(
                "max_attempts",
                sa.Integer(),
                nullable=False,
                server_default=sa.text("3"),
            )
        )
        batch_op.add_column(sa.Column("next_retry_at", sa.DateTime(timezone=True), nullable=True))
        batch_op.add_column(sa.Column("last_heartbeat_at", sa.DateTime(timezone=True), nullable=True))
        batch_op.add_column(sa.Column("cancel_requested_at", sa.DateTime(timezone=True), nullable=True))
        batch_op.create_index("ix_jobs_next_retry_at", ["next_retry_at"], unique=False)
        batch_op.create_index(
            "uq_jobs_profile_type_idempotency",
            ["profile_id", "job_type", "idempotency_key"],
            unique=True,
        )


def downgrade() -> None:
    with op.batch_alter_table("jobs") as batch_op:
        batch_op.drop_index("uq_jobs_profile_type_idempotency")
        batch_op.drop_index("ix_jobs_next_retry_at")
        batch_op.drop_column("cancel_requested_at")
        batch_op.drop_column("last_heartbeat_at")
        batch_op.drop_column("next_retry_at")
        batch_op.drop_column("max_attempts")
        batch_op.drop_column("attempt_count")
        batch_op.drop_column("idempotency_key")
