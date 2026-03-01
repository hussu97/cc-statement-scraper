"""Add missing FK indexes: job_items.job_id, statements.bank_code, statement_lines.statement_id

Revision ID: 20260302_000012
Revises: 20260302_000011
Create Date: 2026-03-02 00:00:12
"""
from __future__ import annotations

from alembic import op


revision = "20260302_000012"
down_revision = "20260302_000011"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_index("ix_job_items_job_id", "job_items", ["job_id"])
    op.create_index("ix_statements_bank_code", "statements", ["bank_code"])
    op.create_index("ix_statement_lines_statement_id", "statement_lines", ["statement_id"])


def downgrade() -> None:
    op.drop_index("ix_statement_lines_statement_id", table_name="statement_lines")
    op.drop_index("ix_statements_bank_code", table_name="statements")
    op.drop_index("ix_job_items_job_id", table_name="job_items")
