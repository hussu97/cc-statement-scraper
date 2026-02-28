"""job_logs table for per-job terminal log capture

Revision ID: 20260301_000009
Revises: 20260228_000008
Create Date: 2026-03-01 00:00:09
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "20260301_000009"
down_revision = "20260228_000008"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "job_logs",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("job_id", sa.Integer(), nullable=False),
        sa.Column("level", sa.String(length=16), nullable=False, server_default="info"),
        sa.Column("logger", sa.String(length=128), nullable=False, server_default=""),
        sa.Column("message", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["job_id"], ["jobs.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_job_logs_job_id", "job_logs", ["job_id"])
    op.create_index("ix_job_logs_created_at", "job_logs", ["created_at"])


def downgrade() -> None:
    op.drop_index("ix_job_logs_created_at", table_name="job_logs")
    op.drop_index("ix_job_logs_job_id", table_name="job_logs")
    op.drop_table("job_logs")
