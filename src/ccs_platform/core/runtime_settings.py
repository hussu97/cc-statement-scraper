from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
from typing import Any

from dotenv import dotenv_values
from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.core.bank_config import ROOT_DIR
from ccs_platform.db import models


@dataclass(frozen=True)
class RuntimeSettingSpec:
    key: str
    bank_code: str | None
    is_secret: bool
    description: str


DEFAULT_RUNTIME_SETTING_SPECS: tuple[RuntimeSettingSpec, ...] = (
    RuntimeSettingSpec("FAB_USERNAME", "FAB", True, "FAB online banking username"),
    RuntimeSettingSpec("FAB_PASSWORD", "FAB", True, "FAB online banking password"),
    RuntimeSettingSpec("ADCB_CID", "ADCB", True, "ADCB customer identifier"),
    RuntimeSettingSpec("ADCB_LOGIN_PASSWORD", "ADCB", True, "ADCB login password"),
    RuntimeSettingSpec("ADCB_PDF_PASSWORD", "ADCB", True, "ADCB PDF password (falls back to ADCB_CID when empty)"),
    RuntimeSettingSpec("ADCB_FORCE_VIRTUAL_KEYBOARD", "ADCB", False, "ADCB virtual keyboard automation toggle"),
    RuntimeSettingSpec("ENBD_USERNAME", "ENBD", True, "ENBD online banking username"),
    RuntimeSettingSpec("ENBD_PASSWORD", "ENBD", True, "ENBD online banking password"),
    RuntimeSettingSpec("SIB_USER_ID", "SIB", True, "SIB online banking user ID"),
    RuntimeSettingSpec("SIB_PASSWORD", "SIB", True, "SIB online banking password"),
    RuntimeSettingSpec("SIB_PDF_PASSWORD", "SIB", True, "SIB PDF password (DOB in DDMMYY format)"),
    RuntimeSettingSpec(
        "SIB_SECURE_IMAGE_TEMPLATE_BASE64",
        "SIB",
        False,
        "Optional SIB secure image template (base64 PNG) for PAM image matching",
    ),
    RuntimeSettingSpec("CCS_DOWNLOADS_DIR", None, False, "Download directory watched by scraper"),
)

DEFAULT_SPEC_MAP = {spec.key: spec for spec in DEFAULT_RUNTIME_SETTING_SPECS}
SUPPORTED_KEY_PREFIXES = ("FAB_", "ADCB_", "ENBD_", "SIB_", "CCS_")
SECRET_TOKENS = ("PASSWORD", "SECRET", "TOKEN", "API_KEY", "KEY", "CID", "USERNAME")


def normalize_runtime_key(key: str) -> str:
    return key.strip().upper()


def infer_bank_code_from_key(key: str) -> str | None:
    upper = normalize_runtime_key(key)
    for bank_code in ("FAB", "ADCB", "ENBD", "SIB"):
        if upper.startswith(f"{bank_code}_"):
            return bank_code
    return None


def infer_is_secret_from_key(key: str) -> bool:
    upper = normalize_runtime_key(key)
    return any(token in upper for token in SECRET_TOKENS)


def is_supported_runtime_key(key: str) -> bool:
    upper = normalize_runtime_key(key)
    return any(upper.startswith(prefix) for prefix in SUPPORTED_KEY_PREFIXES)


def _env_file_values(env_file: Path) -> dict[str, str]:
    if not env_file.exists():
        return {}

    raw = dotenv_values(env_file)
    values: dict[str, str] = {}
    for key, value in raw.items():
        if not key:
            continue
        normalized_key = normalize_runtime_key(key)
        if not is_supported_runtime_key(normalized_key):
            continue
        values[normalized_key] = "" if value is None else str(value)
    return values


def upsert_runtime_setting(
    db: Session,
    *,
    profile_id: int,
    key: str,
    value: str,
    bank_code: str | None = None,
    is_secret: bool | None = None,
    description: str | None = None,
) -> models.RuntimeSetting:
    normalized_key = normalize_runtime_key(key)
    row = db.execute(
        select(models.RuntimeSetting).where(
            models.RuntimeSetting.profile_id == profile_id,
            models.RuntimeSetting.key == normalized_key,
        )
    ).scalar_one_or_none()

    spec = DEFAULT_SPEC_MAP.get(normalized_key)
    resolved_bank_code = (bank_code or (spec.bank_code if spec else infer_bank_code_from_key(normalized_key)) or None)
    if resolved_bank_code:
        resolved_bank_code = resolved_bank_code.upper()

    resolved_is_secret = (
        is_secret
        if is_secret is not None
        else (spec.is_secret if spec else infer_is_secret_from_key(normalized_key))
    )
    resolved_description = description if description is not None else (spec.description if spec else None)

    if row is None:
        row = models.RuntimeSetting(
            profile_id=profile_id,
            key=normalized_key,
            value=value,
            bank_code=resolved_bank_code,
            is_secret=resolved_is_secret,
            description=resolved_description,
        )
        db.add(row)
        return row

    row.value = value
    row.bank_code = resolved_bank_code
    row.is_secret = resolved_is_secret
    row.description = resolved_description
    return row


def seed_runtime_settings_from_env(
    db: Session,
    *,
    profile_id: int,
    env_file: Path | None = None,
    overwrite_existing: bool = False,
    blank_values: bool = False,
) -> dict[str, Any]:
    source_file = env_file or (ROOT_DIR / ".env")
    env_values = _env_file_values(source_file)

    seed_values: dict[str, str] = {}

    # Keep spec catalog deterministic even when .env is incomplete.
    for spec in DEFAULT_RUNTIME_SETTING_SPECS:
        if blank_values:
            seed_values[spec.key] = ""
            continue
        seed_values[spec.key] = env_values.get(spec.key, os.getenv(spec.key, ""))

    # Include extra supported keys from .env as part of catalog for this profile.
    for key, value in env_values.items():
        if key in seed_values:
            continue
        seed_values[key] = "" if blank_values else value

    existing_by_key = {
        row.key: row
        for row in db.execute(
            select(models.RuntimeSetting).where(models.RuntimeSetting.profile_id == profile_id)
        ).scalars().all()
    }

    inserted = 0
    updated = 0
    skipped = 0

    for key in sorted(seed_values):
        if not is_supported_runtime_key(key):
            continue

        value = seed_values.get(key, "")
        row = existing_by_key.get(key)

        spec = DEFAULT_SPEC_MAP.get(key)
        resolved_bank_code = (spec.bank_code if spec else infer_bank_code_from_key(key)) or None
        resolved_is_secret = spec.is_secret if spec else infer_is_secret_from_key(key)
        resolved_description = spec.description if spec else None

        if row is None:
            db.add(
                models.RuntimeSetting(
                    profile_id=profile_id,
                    key=key,
                    value=value,
                    bank_code=resolved_bank_code,
                    is_secret=resolved_is_secret,
                    description=resolved_description,
                )
            )
            inserted += 1
            continue

        metadata_changed = False
        if row.bank_code != resolved_bank_code:
            row.bank_code = resolved_bank_code
            metadata_changed = True
        if row.is_secret != resolved_is_secret:
            row.is_secret = resolved_is_secret
            metadata_changed = True
        if resolved_description and row.description != resolved_description:
            row.description = resolved_description
            metadata_changed = True

        if overwrite_existing and row.value != value:
            row.value = value
            updated += 1
            continue

        if metadata_changed:
            updated += 1
        else:
            skipped += 1

    return {
        "profile_id": profile_id,
        "env_file": str(source_file),
        "inserted": inserted,
        "updated": updated,
        "skipped": skipped,
        "total_seed_candidates": len(seed_values),
        "overwrite_existing": overwrite_existing,
        "blank_values": blank_values,
    }


def apply_runtime_settings_to_process_env(db: Session, *, profile_id: int) -> int:
    # Reset managed keyspace so profile switches never leave stale values.
    for key in list(os.environ.keys()):
        if any(key.startswith(prefix) for prefix in SUPPORTED_KEY_PREFIXES):
            os.environ.pop(key, None)

    rows = db.execute(
        select(models.RuntimeSetting)
        .where(models.RuntimeSetting.profile_id == profile_id)
        .order_by(models.RuntimeSetting.key.asc())
    ).scalars().all()

    applied = 0
    for row in rows:
        value = row.value or ""
        if not value:
            continue
        os.environ[row.key] = value
        applied += 1
    return applied
