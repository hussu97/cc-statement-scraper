"""initial platform schema

Revision ID: 20260225_000001
Revises: 
Create Date: 2026-02-25 00:00:01
"""
from __future__ import annotations

from alembic import op

from ccs_platform.db import Base
from ccs_platform.db import models  # noqa: F401


revision = "20260225_000001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    Base.metadata.create_all(bind=bind)


def downgrade() -> None:
    bind = op.get_bind()
    Base.metadata.drop_all(bind=bind)
