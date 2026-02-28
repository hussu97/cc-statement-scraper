#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from ccs_platform.core.settings import get_settings
from ccs_platform.operations.backups import run_backup_restore_drill


def main() -> int:
    parser = argparse.ArgumentParser(description="Run backup/restore drill with integrity verification.")
    parser.add_argument("--output-dir", default="", help="Backup output directory")
    parser.add_argument("--label", default="drill", help="Optional label for drill backup")
    args = parser.parse_args()

    settings = get_settings()
    output_dir = Path(args.output_dir).expanduser().resolve() if args.output_dir else None
    result = run_backup_restore_drill(settings, output_dir=output_dir, label=args.label or None)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
