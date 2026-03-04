"""category_override table and column

Revision ID: 20260304_000014
Revises: 20260302_000013
Create Date: 2026-03-04

"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "20260304_000014"
down_revision = "20260302_000013"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "category_overrides",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("fingerprint", sa.String(64), nullable=False, unique=True),
        sa.Column("category_name", sa.String(128), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_category_overrides_fingerprint", "category_overrides", ["fingerprint"])

    with op.batch_alter_table("statement_lines") as batch_op:
        batch_op.add_column(sa.Column("category_override", sa.String(128), nullable=True))
        batch_op.create_index("ix_statement_lines_category_override", ["category_override"])


def downgrade() -> None:
    with op.batch_alter_table("statement_lines") as batch_op:
        batch_op.drop_index("ix_statement_lines_category_override")
        batch_op.drop_column("category_override")

    op.drop_index("ix_category_overrides_fingerprint", table_name="category_overrides")
    op.drop_table("category_overrides")
