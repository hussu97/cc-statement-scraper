#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json

from ccs_platform.core.settings import get_settings
from ccs_platform.operations.migrations import run_migration_preflight


def main() -> int:
    parser = argparse.ArgumentParser(description="Run migration governance preflight checks.")
    parser.add_argument("--database-url", default="", help="Optional DB URL override for revision-state check")
    parser.add_argument(
        "--skip-database-state",
        action="store_true",
        help="Skip checking DB revision against alembic head",
    )
    args = parser.parse_args()

    report = run_migration_preflight(
        get_settings(),
        database_url=args.database_url or None,
        check_database_state=not bool(args.skip_database_state),
    )
    print(json.dumps(report, indent=2))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
