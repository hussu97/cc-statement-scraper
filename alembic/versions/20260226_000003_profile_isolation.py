"""profile isolation for operational tables

Revision ID: 20260226_000003
Revises: 20260226_000002
Create Date: 2026-02-26 00:00:03
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op


revision = "20260226_000003"
down_revision = "20260226_000002"
branch_labels = None
depends_on = None


OPERATIONAL_TABLES = (
    "runtime_settings",
    "pdf_files",
    "statements",
    "jobs",
    "schedules",
    "exports",
    "audit_events",
)


def _drop_unique_if_exists(table_name: str, column_names: tuple[str, ...]) -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    for item in inspector.get_unique_constraints(table_name):
        constrained = tuple(item.get("column_names") or [])
        if constrained != column_names:
            continue
        name = item.get("name")
        if not name:
            continue
        with op.batch_alter_table(table_name) as batch_op:
            batch_op.drop_constraint(name, type_="unique")


def upgrade() -> None:
    op.create_table(
        "profiles",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("key", sa.String(length=64), nullable=False),
        sa.Column("name", sa.String(length=128), nullable=False),
        sa.Column("is_default", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("key"),
    )
    op.create_index("ix_profiles_key", "profiles", ["key"], unique=False)

    op.create_table(
        "profile_banks",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("profile_id", sa.Integer(), nullable=False),
        sa.Column("bank_code", sa.String(length=16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["profile_id"], ["profiles.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["bank_code"], ["banks.code"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("profile_id", "bank_code", name="uq_profile_bank"),
    )
    op.create_index("ix_profile_banks_profile_id", "profile_banks", ["profile_id"], unique=False)
    op.create_index("ix_profile_banks_bank_code", "profile_banks", ["bank_code"], unique=False)

    profiles_table = sa.table(
        "profiles",
        sa.column("key", sa.String()),
        sa.column("name", sa.String()),
        sa.column("is_default", sa.Boolean()),
    )
    op.bulk_insert(
        profiles_table,
        [
            {"key": "hussain", "name": "Hussain", "is_default": True},
            {"key": "tejasvie", "name": "Tejasvie", "is_default": False},
        ],
    )

    bind = op.get_bind()
    hussain_profile_id = bind.execute(sa.text("SELECT id FROM profiles WHERE key = 'hussain'")).scalar_one()

    for table_name in OPERATIONAL_TABLES:
        op.add_column(table_name, sa.Column("profile_id", sa.Integer(), nullable=True))
        bind.execute(
            sa.text(f"UPDATE {table_name} SET profile_id = :profile_id WHERE profile_id IS NULL"),
            {"profile_id": hussain_profile_id},
        )

    _drop_unique_if_exists("runtime_settings", ("key",))
    _drop_unique_if_exists("statements", ("bank_code", "statement_reference", "statement_date"))

    with op.batch_alter_table("runtime_settings") as batch_op:
        batch_op.alter_column("profile_id", nullable=False)
        batch_op.create_foreign_key(
            "fk_runtime_settings_profile_id_profiles",
            "profiles",
            ["profile_id"],
            ["id"],
            ondelete="CASCADE",
        )
        batch_op.create_unique_constraint("uq_runtime_settings_profile_key", ["profile_id", "key"])
        batch_op.create_index("ix_runtime_settings_profile_id", ["profile_id"], unique=False)

    with op.batch_alter_table("pdf_files") as batch_op:
        batch_op.alter_column("profile_id", nullable=False)
        batch_op.create_foreign_key(
            "fk_pdf_files_profile_id_profiles",
            "profiles",
            ["profile_id"],
            ["id"],
            ondelete="RESTRICT",
        )
        batch_op.create_index("ix_pdf_files_profile_id", ["profile_id"], unique=False)

    with op.batch_alter_table("statements") as batch_op:
        batch_op.alter_column("profile_id", nullable=False)
        batch_op.create_foreign_key(
            "fk_statements_profile_id_profiles",
            "profiles",
            ["profile_id"],
            ["id"],
            ondelete="RESTRICT",
        )
        batch_op.create_index("ix_statements_profile_id", ["profile_id"], unique=False)
        batch_op.create_unique_constraint(
            "uq_statement_identity",
            ["profile_id", "bank_code", "statement_reference", "statement_date"],
        )

    with op.batch_alter_table("jobs") as batch_op:
        batch_op.alter_column("profile_id", nullable=False)
        batch_op.create_foreign_key(
            "fk_jobs_profile_id_profiles",
            "profiles",
            ["profile_id"],
            ["id"],
            ondelete="RESTRICT",
        )
        batch_op.create_index("ix_jobs_profile_id", ["profile_id"], unique=False)

    with op.batch_alter_table("schedules") as batch_op:
        batch_op.alter_column("profile_id", nullable=False)
        batch_op.create_foreign_key(
            "fk_schedules_profile_id_profiles",
            "profiles",
            ["profile_id"],
            ["id"],
            ondelete="RESTRICT",
        )
        batch_op.create_index("ix_schedules_profile_id", ["profile_id"], unique=False)

    with op.batch_alter_table("exports") as batch_op:
        batch_op.alter_column("profile_id", nullable=False)
        batch_op.create_foreign_key(
            "fk_exports_profile_id_profiles",
            "profiles",
            ["profile_id"],
            ["id"],
            ondelete="RESTRICT",
        )
        batch_op.create_index("ix_exports_profile_id", ["profile_id"], unique=False)

    with op.batch_alter_table("audit_events") as batch_op:
        batch_op.alter_column("profile_id", nullable=False)
        batch_op.create_foreign_key(
            "fk_audit_events_profile_id_profiles",
            "profiles",
            ["profile_id"],
            ["id"],
            ondelete="RESTRICT",
        )
        batch_op.create_index("ix_audit_events_profile_id", ["profile_id"], unique=False)

    bank_codes = bind.execute(sa.text("SELECT code FROM banks ORDER BY code")).scalars().all()
    profile_banks_table = sa.table(
        "profile_banks",
        sa.column("profile_id", sa.Integer()),
        sa.column("bank_code", sa.String()),
    )
    if bank_codes:
        op.bulk_insert(
            profile_banks_table,
            [{"profile_id": hussain_profile_id, "bank_code": code} for code in bank_codes],
        )


def downgrade() -> None:
    with op.batch_alter_table("audit_events") as batch_op:
        batch_op.drop_index("ix_audit_events_profile_id")
        batch_op.drop_constraint("fk_audit_events_profile_id_profiles", type_="foreignkey")
        batch_op.drop_column("profile_id")

    with op.batch_alter_table("exports") as batch_op:
        batch_op.drop_index("ix_exports_profile_id")
        batch_op.drop_constraint("fk_exports_profile_id_profiles", type_="foreignkey")
        batch_op.drop_column("profile_id")

    with op.batch_alter_table("schedules") as batch_op:
        batch_op.drop_index("ix_schedules_profile_id")
        batch_op.drop_constraint("fk_schedules_profile_id_profiles", type_="foreignkey")
        batch_op.drop_column("profile_id")

    with op.batch_alter_table("jobs") as batch_op:
        batch_op.drop_index("ix_jobs_profile_id")
        batch_op.drop_constraint("fk_jobs_profile_id_profiles", type_="foreignkey")
        batch_op.drop_column("profile_id")

    with op.batch_alter_table("statements") as batch_op:
        batch_op.drop_constraint("uq_statement_identity", type_="unique")
        batch_op.create_unique_constraint("uq_statement_identity", ["bank_code", "statement_reference", "statement_date"])
        batch_op.drop_index("ix_statements_profile_id")
        batch_op.drop_constraint("fk_statements_profile_id_profiles", type_="foreignkey")
        batch_op.drop_column("profile_id")

    with op.batch_alter_table("pdf_files") as batch_op:
        batch_op.drop_index("ix_pdf_files_profile_id")
        batch_op.drop_constraint("fk_pdf_files_profile_id_profiles", type_="foreignkey")
        batch_op.drop_column("profile_id")

    with op.batch_alter_table("runtime_settings") as batch_op:
        batch_op.drop_constraint("uq_runtime_settings_profile_key", type_="unique")
        batch_op.create_unique_constraint("uq_runtime_settings_key", ["key"])
        batch_op.drop_index("ix_runtime_settings_profile_id")
        batch_op.drop_constraint("fk_runtime_settings_profile_id_profiles", type_="foreignkey")
        batch_op.drop_column("profile_id")

    op.drop_index("ix_profile_banks_bank_code", table_name="profile_banks")
    op.drop_index("ix_profile_banks_profile_id", table_name="profile_banks")
    op.drop_table("profile_banks")

    op.drop_index("ix_profiles_key", table_name="profiles")
    op.drop_table("profiles")
