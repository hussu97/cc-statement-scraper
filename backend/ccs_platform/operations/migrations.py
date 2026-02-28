from __future__ import annotations

import ast
from pathlib import Path
from typing import Any

from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine

from ccs_platform.core.settings import ROOT_DIR, PlatformSettings


def _function_has_logic(function: ast.FunctionDef) -> bool:
    for statement in function.body:
        if isinstance(statement, ast.Pass):
            continue
        if (
            isinstance(statement, ast.Expr)
            and isinstance(statement.value, ast.Constant)
            and isinstance(statement.value.value, str)
        ):
            continue
        return True
    return False


def _inspect_migration_file(path: Path) -> list[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    functions = {
        node.name: node
        for node in tree.body
        if isinstance(node, ast.FunctionDef)
    }

    issues: list[str] = []
    for fn_name in ("upgrade", "downgrade"):
        fn = functions.get(fn_name)
        if fn is None:
            issues.append(f"{path.name}: missing {fn_name}()")
            continue
        if not _function_has_logic(fn):
            issues.append(f"{path.name}: {fn_name}() has no operations")
    return issues


def run_migration_preflight(
    settings: PlatformSettings,
    *,
    database_url: str | None = None,
    check_database_state: bool = True,
) -> dict[str, Any]:
    alembic_ini = ROOT_DIR / "alembic.ini"
    versions_dir = ROOT_DIR / "alembic" / "versions"

    config = Config(str(alembic_ini))
    target_database_url = (database_url or settings.resolved_database_url()).strip()
    config.set_main_option("sqlalchemy.url", target_database_url)

    script_dir = ScriptDirectory.from_config(config)
    heads = script_dir.get_heads()
    current_head = script_dir.get_current_head()
    revision_count = sum(1 for _ in script_dir.walk_revisions(base="base", head="heads"))

    file_issues: list[str] = []
    for migration_file in sorted(versions_dir.glob("*.py")):
        file_issues.extend(_inspect_migration_file(migration_file))

    graph_issues: list[str] = []
    if len(heads) != 1:
        graph_issues.append(f"Expected exactly one migration head, found {len(heads)}")

    current_revision: str | None = None
    pending_migration_count: int | None = None
    database_issues: list[str] = []
    if check_database_state:
        engine = create_engine(target_database_url, future=True)
        try:
            with engine.connect() as connection:
                context = MigrationContext.configure(connection)
                current_revision = context.get_current_revision()
        finally:
            engine.dispose()

        pending_migration_count = 0 if current_revision == current_head else 1
        if current_revision != current_head:
            database_issues.append(
                f"Database revision ({current_revision}) does not match head ({current_head})"
            )

    issues = [*file_issues, *graph_issues, *database_issues]
    return {
        "ok": not issues,
        "alembic_ini": str(alembic_ini),
        "database_url": target_database_url,
        "current_revision": current_revision,
        "current_head": current_head,
        "head_count": len(heads),
        "revision_count": revision_count,
        "pending_migration_count": pending_migration_count,
        "issues": issues,
    }
