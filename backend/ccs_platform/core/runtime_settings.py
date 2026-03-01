from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
from typing import Any

from dotenv import dotenv_values
from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.core.secret_codec import decode_secret, encode_secret, is_encoded
from ccs_platform.core.settings import get_settings
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
    RuntimeSettingSpec("ENBD_PDF_PASSWORD", "ENBD", True, "ENBD PDF password (required for email-sourced encrypted statements)"),
    RuntimeSettingSpec("EIB_USERNAME", "EIB", True, "EIB online banking username"),
    RuntimeSettingSpec("EIB_PASSWORD", "EIB", True, "EIB online banking password"),
    RuntimeSettingSpec("SIB_USER_ID", "SIB", True, "SIB online banking user ID"),
    RuntimeSettingSpec("SIB_PASSWORD", "SIB", True, "SIB online banking password"),
    RuntimeSettingSpec("SIB_PDF_PASSWORD", "SIB", True, "SIB PDF password (DOB in DDMMYY format)"),
    RuntimeSettingSpec(
        "SIB_SECURE_IMAGE_TEMPLATE_BASE64",
        "SIB",
        False,
        "Optional SIB secure image template (base64 PNG) for PAM image matching",
    ),
    RuntimeSettingSpec("MASHREQ_USERNAME", "MASHREQ", True, "Mashreq online banking username"),
    RuntimeSettingSpec("MASHREQ_PASSWORD", "MASHREQ", True, "Mashreq online banking password"),
)

DEFAULT_SPEC_MAP = {spec.key: spec for spec in DEFAULT_RUNTIME_SETTING_SPECS}
SUPPORTED_KEY_PREFIXES = ("FAB_", "ADCB_", "ENBD_", "EIB_", "SIB_", "MASHREQ_", "EMAIL_")
SECRET_TOKENS = ("PASSWORD", "SECRET", "TOKEN", "API_KEY", "KEY", "CID", "USERNAME")


def normalize_runtime_key(key: str) -> str:
    return key.strip().upper()


def infer_bank_code_from_key(key: str) -> str | None:
    upper = normalize_runtime_key(key)
    for bank_code in ("FAB", "ADCB", "ENBD", "EIB", "SIB", "MASHREQ"):
        if upper.startswith(f"{bank_code}_"):
            return bank_code
    return None


def infer_is_secret_from_key(key: str) -> bool:
    upper = normalize_runtime_key(key)
    return any(token in upper for token in SECRET_TOKENS)


def is_supported_runtime_key(key: str) -> bool:
    upper = normalize_runtime_key(key)
    return any(upper.startswith(prefix) for prefix in SUPPORTED_KEY_PREFIXES)


def decode_runtime_setting_value(*, value: str, is_secret: bool) -> str:
    if not value:
        return ""
    if not is_secret:
        return value
    try:
        return decode_secret(value)
    except RuntimeError:
        settings = get_settings()
        if settings.runtime_settings_encryption_required():
            raise
        # Development fallback: keep startup usable even if old encrypted
        # values exist but no key is configured in current environment.
        return ""


def encode_runtime_setting_value(*, value: str, is_secret: bool) -> str:
    if not value:
        return ""
    if not is_secret:
        return value

    settings = get_settings()
    if not settings.runtime_settings_encryption_key:
        if settings.runtime_settings_encryption_required():
            raise RuntimeError(
                "Runtime secret persistence encryption is required. "
                "Set CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY."
            )
        return value

    if is_encoded(value):
        return value

    return encode_secret(value)


def decode_runtime_setting_row_value(row: models.RuntimeSetting) -> str:
    return decode_runtime_setting_value(value=row.value or "", is_secret=row.is_secret)


def _normalize_raw_env_values(raw_values: dict[str, Any]) -> dict[str, str]:
    values: dict[str, str] = {}
    for key, value in raw_values.items():
        if not key:
            continue
        normalized_key = normalize_runtime_key(key)
        values[normalized_key] = "" if value is None else str(value)
    return values


def _split_runtime_env_values(
    values: dict[str, str], *, profile_key: str | None
) -> tuple[dict[str, str], dict[str, str]]:
    default_values: dict[str, str] = {}
    profile_scoped_values: dict[str, str] = {}

    normalized_profile_key = normalize_runtime_key(profile_key or "")
    profile_prefixes: tuple[str, ...] = ()
    if normalized_profile_key:
        profile_prefixes = (
            f"{normalized_profile_key}__",
            f"{normalized_profile_key}_",
        )

    for key, value in values.items():
        normalized_key = normalize_runtime_key(key)
        if is_supported_runtime_key(normalized_key):
            default_values[normalized_key] = value

        if not profile_prefixes:
            continue

        scoped_key: str | None = None
        for prefix in profile_prefixes:
            if normalized_key.startswith(prefix):
                scoped_key = normalized_key[len(prefix) :]
                break
        if scoped_key is None:
            continue
        if not is_supported_runtime_key(scoped_key):
            continue
        profile_scoped_values[scoped_key] = value

    return default_values, profile_scoped_values


def _env_file_values(env_file: Path) -> dict[str, str]:
    if not env_file.exists():
        return {}
    raw = dotenv_values(env_file)
    return _normalize_raw_env_values(raw)


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
    stored_value = encode_runtime_setting_value(value=value, is_secret=resolved_is_secret)
    resolved_description = description if description is not None else (spec.description if spec else None)

    if row is None:
        row = models.RuntimeSetting(
            profile_id=profile_id,
            key=normalized_key,
            value=stored_value,
            bank_code=resolved_bank_code,
            is_secret=resolved_is_secret,
            description=resolved_description,
        )
        db.add(row)
        return row

    row.value = stored_value
    row.bank_code = resolved_bank_code
    row.is_secret = resolved_is_secret
    row.description = resolved_description
    return row


def seed_runtime_settings_from_env(
    db: Session,
    *,
    profile_id: int,
    profile_key: str | None = None,
    env_file: Path | None = None,
    overwrite_existing: bool = False,
    blank_values: bool = False,
    source_mode: str | None = None,
) -> dict[str, Any]:
    settings = get_settings()
    resolved_source_mode = (source_mode or settings.runtime_settings_seed_source_mode()).strip().lower()
    allowed_source_modes = {"env", "env_file", "env_file_then_env", "none"}
    if resolved_source_mode not in allowed_source_modes:
        raise ValueError(
            "Unsupported runtime settings seed source mode. "
            "Expected one of: env, env_file, env_file_then_env, none."
        )

    source_file = env_file if env_file is not None else settings.runtime_settings_env_file
    resolved_profile_key = (profile_key or "").strip()
    if not resolved_profile_key:
        resolved_profile_key = (
            db.execute(select(models.Profile.key).where(models.Profile.id == profile_id))
            .scalar_one_or_none()
            or ""
        ).strip()

    use_env_file = resolved_source_mode in {"env_file", "env_file_then_env"}
    include_process_env = resolved_source_mode in {"env", "env_file_then_env"}
    env_values = _env_file_values(source_file) if (use_env_file and source_file is not None) else {}
    env_default_values, env_profile_values = _split_runtime_env_values(
        env_values, profile_key=resolved_profile_key
    )
    process_default_values: dict[str, str] = {}
    process_profile_values: dict[str, str] = {}
    if include_process_env:
        process_default_values, process_profile_values = _split_runtime_env_values(
            _normalize_raw_env_values(dict(os.environ)),
            profile_key=resolved_profile_key,
        )

    def _value_for_spec(key: str) -> str:
        if resolved_source_mode == "none":
            return ""

        process_default = process_default_values.get(key, "")
        process_profile = process_profile_values.get(key, "")
        file_default = env_default_values.get(key, "")
        file_profile = env_profile_values.get(key, "")

        if blank_values:
            # Non-default profiles only ingest profile-scoped keys.
            if resolved_source_mode == "env":
                return process_profile
            if resolved_source_mode == "env_file":
                return file_profile
            # env_file_then_env: prefer .env profile-scoped value, then process env.
            return file_profile or process_profile

        if resolved_source_mode == "env":
            return process_profile or process_default
        if resolved_source_mode == "env_file":
            return file_profile or file_default
        # env_file_then_env: prefer .env (updated source of truth), then process env fallback.
        return file_profile or file_default or process_profile or process_default

    seed_values: dict[str, str] = {}

    # Keep spec catalog deterministic even when .env is incomplete.
    for spec in DEFAULT_RUNTIME_SETTING_SPECS:
        seed_values[spec.key] = _value_for_spec(spec.key)

    # Include extra supported keys from discovered env sources as part of catalog.
    if blank_values:
        extra_source = {
            **env_profile_values,
            **process_profile_values,
        }
    else:
        extra_source = {
            **env_default_values,
            **env_profile_values,
            **process_default_values,
            **process_profile_values,
        }
    for key, value in extra_source.items():
        if key in seed_values or not is_supported_runtime_key(key):
            continue
        seed_values[key] = _value_for_spec(key)

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
            stored_value = encode_runtime_setting_value(value=value, is_secret=resolved_is_secret)
            db.add(
                models.RuntimeSetting(
                    profile_id=profile_id,
                    key=key,
                    value=stored_value,
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
            plain_current_value = decode_runtime_setting_value(value=row.value or "", is_secret=row.is_secret)
            row.is_secret = resolved_is_secret
            row.value = encode_runtime_setting_value(value=plain_current_value, is_secret=resolved_is_secret)
            metadata_changed = True
        if resolved_description and row.description != resolved_description:
            row.description = resolved_description
            metadata_changed = True

        current_plain_value = decode_runtime_setting_value(value=row.value or "", is_secret=row.is_secret)
        if overwrite_existing and current_plain_value != value:
            row.value = encode_runtime_setting_value(value=value, is_secret=row.is_secret)
            updated += 1
            continue

        if metadata_changed:
            updated += 1
        else:
            skipped += 1

    return {
        "profile_id": profile_id,
        "profile_key": resolved_profile_key or None,
        "env_file": str(source_file) if source_file is not None else None,
        "source_mode": resolved_source_mode,
        "inserted": inserted,
        "updated": updated,
        "skipped": skipped,
        "total_seed_candidates": len(seed_values),
        "overwrite_existing": overwrite_existing,
        "blank_values": blank_values,
    }


def get_runtime_settings_as_dict(db: Session, *, profile_id: int) -> dict[str, str]:
    """Return runtime settings for a profile as a plain dict without mutating os.environ."""
    rows = db.execute(
        select(models.RuntimeSetting)
        .where(models.RuntimeSetting.profile_id == profile_id)
        .order_by(models.RuntimeSetting.key.asc())
    ).scalars().all()

    result: dict[str, str] = {}
    for row in rows:
        value = decode_runtime_setting_value(value=row.value or "", is_secret=row.is_secret)
        if value:
            result[row.key] = value
    return result


def apply_runtime_settings_to_process_env(db: Session, *, profile_id: int) -> int:
    # Reset managed keyspace so profile switches never leave stale values.
    for key in list(os.environ.keys()):
        if any(key.startswith(prefix) for prefix in SUPPORTED_KEY_PREFIXES):
            os.environ.pop(key, None)

    credentials = get_runtime_settings_as_dict(db, profile_id=profile_id)
    for key, value in credentials.items():
        os.environ[key] = value
    return len(credentials)
