#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from ccs_platform.core.settings import get_settings
from ccs_platform.operations.backups import restore_backup_archive


def main() -> int:
    parser = argparse.ArgumentParser(description="Restore CCS backup archive.")
    parser.add_argument("archive", help="Path to backup .tar.gz archive")
    parser.add_argument("--force", action="store_true", help="Allow overwriting existing DB/data")
    parser.add_argument("--skip-archive", action="store_true", help="Skip restoring storage archive files")
    parser.add_argument("--restore-uploads", action="store_true", help="Restore uploads directory")
    parser.add_argument("--restore-logs", action="store_true", help="Restore logs directory")
    args = parser.parse_args()

    settings = get_settings()
    summary = restore_backup_archive(
        settings,
        archive_path=Path(args.archive).expanduser().resolve(),
        force=bool(args.force),
        restore_archive=not args.skip_archive,
        restore_uploads=bool(args.restore_uploads),
        restore_logs=bool(args.restore_logs),
    )
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
