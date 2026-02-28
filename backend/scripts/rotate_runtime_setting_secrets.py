#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os

from sqlalchemy import select

from ccs_platform.db import models
from ccs_platform.db.session import SessionLocal


ENC_PREFIX = "enc:v1:"


def _load_fernet_from_env(var_name: str) -> object:
    value = (os.getenv(var_name) or "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {var_name}")

    try:
        from cryptography.fernet import Fernet
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError("cryptography package is required for secret rotation drill.") from exc

    return Fernet(value.encode("utf-8"))


def _decrypt(value: str, *, old_fernet: object | None, new_fernet: object) -> str:
    if not value:
        return ""
    if not value.startswith(ENC_PREFIX):
        return value

    token = value[len(ENC_PREFIX):].encode("utf-8")
    try:
        return new_fernet.decrypt(token).decode("utf-8")
    except Exception:  # noqa: BLE001
        if old_fernet is None:
            raise RuntimeError(
                "Encountered encrypted value that cannot be decrypted with new key, "
                "and old key was not provided."
            )
        try:
            return old_fernet.decrypt(token).decode("utf-8")
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError("Failed to decrypt existing encrypted runtime setting value.") from exc


def _encrypt(value: str, *, new_fernet: object) -> str:
    if not value:
        return ""
    token = new_fernet.encrypt(value.encode("utf-8")).decode("utf-8")
    return f"{ENC_PREFIX}{token}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Rotate encrypted runtime setting secrets to a new key.")
    parser.add_argument(
        "--old-key-env",
        default="CCS_PLATFORM_RUNTIME_SETTINGS_OLD_ENCRYPTION_KEY",
        help="Environment variable containing the old Fernet key.",
    )
    parser.add_argument(
        "--new-key-env",
        default="CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY",
        help="Environment variable containing the new Fernet key.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Validate and count changes without writing updates.")
    args = parser.parse_args()

    new_fernet = _load_fernet_from_env(args.new_key_env)
    old_fernet = None
    if os.getenv(args.old_key_env):
        old_fernet = _load_fernet_from_env(args.old_key_env)

    scanned = 0
    updated = 0
    unchanged = 0

    with SessionLocal() as db:
        rows = db.execute(
            select(models.RuntimeSetting).where(models.RuntimeSetting.is_secret.is_(True))
        ).scalars().all()

        for row in rows:
            scanned += 1
            plain = _decrypt(row.value or "", old_fernet=old_fernet, new_fernet=new_fernet)
            rotated = _encrypt(plain, new_fernet=new_fernet)
            if rotated == (row.value or ""):
                unchanged += 1
                continue
            updated += 1
            if not args.dry_run:
                row.value = rotated

        if not args.dry_run:
            db.commit()

    mode = "dry-run" if args.dry_run else "applied"
    print(
        f"Runtime secret rotation {mode} | "
        f"scanned={scanned} updated={updated} unchanged={unchanged}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
