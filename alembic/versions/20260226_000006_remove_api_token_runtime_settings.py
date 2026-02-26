"""remove deprecated api token runtime settings

Revision ID: 20260226_000006
Revises: 20260226_000005
Create Date: 2026-02-26 00:00:06
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260226_000006"
down_revision = "20260226_000005"
branch_labels = None
depends_on = None


DEPRECATED_KEYS = (
    "CCS_PLATFORM_REQUIRE_API_AUTH",
    "CCS_PLATFORM_API_AUTH_TOKEN",
    "CCS_PLATFORM_API_AUTH_EXEMPT_PATHS",
    "CCS_PLATFORM_API_AUTH_DEFAULT_ROLE",
    "CCS_PLATFORM_API_AUTH_TOKEN_ROLES",
    "CCS_PLATFORM_RBAC_ENABLED",
    "CCS_PLATFORM_ACTOR_ROLE_HEADER",
)


def upgrade() -> None:
    runtime_settings = sa.table(
        "runtime_settings",
        sa.column("key", sa.String()),
    )
    op.execute(
        sa.delete(runtime_settings).where(runtime_settings.c.key.in_(DEPRECATED_KEYS))
    )


def downgrade() -> None:
    # Data-only cleanup migration: no schema rollback required.
    return None
