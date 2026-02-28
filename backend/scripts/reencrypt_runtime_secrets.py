#!/usr/bin/env python3
from __future__ import annotations

from sqlalchemy import select

from ccs_platform.core.runtime_settings import decode_runtime_setting_value, encode_runtime_setting_value
from ccs_platform.db import models
from ccs_platform.db.session import SessionLocal


def main() -> int:
    updated = 0

    with SessionLocal() as db:
        rows = db.execute(
            select(models.RuntimeSetting).where(models.RuntimeSetting.is_secret.is_(True))
        ).scalars().all()

        for row in rows:
            plain_value = decode_runtime_setting_value(value=row.value or "", is_secret=True)
            encoded_value = encode_runtime_setting_value(value=plain_value, is_secret=True)
            if encoded_value != (row.value or ""):
                row.value = encoded_value
                updated += 1

        db.commit()

    print(f"Re-encrypted secret runtime settings: {updated}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
