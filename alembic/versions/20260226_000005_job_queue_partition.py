"""job queue partition metadata

Revision ID: 20260226_000005
Revises: 20260226_000004
Create Date: 2026-02-26 00:00:05
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260226_000005"
down_revision = "20260226_000004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("jobs") as batch_op:
        batch_op.add_column(
            sa.Column(
                "queue_name",
                sa.String(length=32),
                nullable=False,
                server_default=sa.text("'default'"),
            )
        )
        batch_op.create_index(
            "ix_jobs_queue_status_created",
            ["queue_name", "status", "created_at"],
            unique=False,
        )


def downgrade() -> None:
    with op.batch_alter_table("jobs") as batch_op:
        batch_op.drop_index("ix_jobs_queue_status_created")
        batch_op.drop_column("queue_name")
