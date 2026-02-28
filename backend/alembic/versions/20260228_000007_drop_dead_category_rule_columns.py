"""Drop dead CategoryRule columns: bank_code, card_last4, priority

Revision ID: 20260228_000007
Revises: 20260226_000006_remove_api_token_runtime_settings
Create Date: 2026-02-28

These three columns have been no-ops since the categorization engine was
simplified to match on merchant name only.  bank_code and card_last4 were
always set to NULL at write-time; priority was always reset to 100.  The
corresponding index on priority is also dropped.
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "20260228_000007"
down_revision = "20260226_000006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("category_rules") as batch_op:
        batch_op.drop_index("ix_category_rules_priority")
        batch_op.drop_column("priority")
        batch_op.drop_column("bank_code")
        batch_op.drop_column("card_last4")


def downgrade() -> None:
    with op.batch_alter_table("category_rules") as batch_op:
        batch_op.add_column(sa.Column("card_last4", sa.String(4), nullable=True))
        batch_op.add_column(sa.Column("bank_code", sa.String(16), nullable=True))
        batch_op.add_column(sa.Column("priority", sa.Integer(), nullable=False, server_default="100"))
        batch_op.create_index("ix_category_rules_priority", ["priority"])
