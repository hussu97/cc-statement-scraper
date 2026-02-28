#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import UTC, datetime
import json

from ccs_platform.core.settings import get_settings
from ccs_platform.operations.retention import enforce_retention


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply or simulate retention policy cleanup.")
    parser.add_argument("--apply", action="store_true", help="Apply deletion changes (default is dry-run)")
    parser.add_argument("--at", default="", help="Override evaluation timestamp (ISO-8601 UTC)")
    args = parser.parse_args()

    now = None
    if args.at:
        parsed = datetime.fromisoformat(args.at)
        now = parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=UTC)

    result = enforce_retention(
        get_settings(),
        dry_run=not bool(args.apply),
        now_utc=now,
    )
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
