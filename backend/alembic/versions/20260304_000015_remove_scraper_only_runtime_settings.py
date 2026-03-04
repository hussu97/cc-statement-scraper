"""remove scraper-only runtime settings from seed catalog

Revision ID: 20260304_000015
Revises: 20260304_000014
Create Date: 2026-03-04

"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260304_000015"
down_revision = "20260304_000014"
branch_labels = None
depends_on = None


# Keys that were seeded by DEFAULT_RUNTIME_SETTING_SPECS but are only consumed
# by the standalone scraper CLI — not by any backend job handler or parser.
SCRAPER_ONLY_KEYS = (
    "FAB_USERNAME",
    "FAB_PASSWORD",
    "ADCB_LOGIN_PASSWORD",
    "ADCB_FORCE_VIRTUAL_KEYBOARD",
    "ENBD_USERNAME",
    "ENBD_PASSWORD",
    "EIB_USERNAME",
    "EIB_PASSWORD",
    "SIB_USER_ID",
    "SIB_PASSWORD",
    "SIB_SECURE_IMAGE_TEMPLATE_BASE64",
    "MASHREQ_USERNAME",
    "MASHREQ_PASSWORD",
)


def upgrade() -> None:
    runtime_settings = sa.table(
        "runtime_settings",
        sa.column("key", sa.String()),
    )
    op.execute(
        sa.delete(runtime_settings).where(runtime_settings.c.key.in_(SCRAPER_ONLY_KEYS))
    )


def downgrade() -> None:
    # Data-only cleanup migration: no schema rollback required.
    return None
