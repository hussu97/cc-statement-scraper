#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from ccs_platform.core.settings import get_settings
from ccs_platform.operations.backups import create_backup_archive


def main() -> int:
    parser = argparse.ArgumentParser(description="Create CCS backup archive (DB + storage snapshot).")
    parser.add_argument("--output-dir", default="", help="Backup output directory (default: settings.backups_dir)")
    parser.add_argument("--label", default="", help="Optional backup label suffix")
    parser.add_argument("--include-uploads", action="store_true", help="Include uploads temp directory")
    parser.add_argument("--include-logs", action="store_true", help="Include logs directory")
    parser.add_argument("--exclude-archive", action="store_true", help="Exclude local storage archive files")
    args = parser.parse_args()

    settings = get_settings()
    output_dir = Path(args.output_dir).expanduser().resolve() if args.output_dir else None

    plan = create_backup_archive(
        settings,
        output_dir=output_dir,
        label=args.label or None,
        include_archive=not args.exclude_archive,
        include_uploads=bool(args.include_uploads),
        include_logs=bool(args.include_logs),
    )
    print(
        json.dumps(
            {
                "archive_path": str(plan.archive_path),
                "manifest": plan.manifest,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
