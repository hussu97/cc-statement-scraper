from __future__ import annotations

import base64
import binascii
from functools import lru_cache

from ccs_platform.core.settings import get_settings


ENC_PREFIX = "enc:v1:"


def is_encoded(value: str) -> bool:
    return value.startswith(ENC_PREFIX)


@lru_cache(maxsize=1)
def _fernet_for_settings() -> object:
    settings = get_settings()
    raw_key = (settings.runtime_settings_encryption_key or "").strip()
    if not raw_key:
        raise RuntimeError(
            "Runtime settings encryption key missing. Set CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY."
        )

    try:
        key_bytes = raw_key.encode("utf-8")
        decoded = base64.urlsafe_b64decode(key_bytes)
    except (binascii.Error, ValueError) as exc:
        raise RuntimeError(
            "Invalid CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY format. "
            "Expected a Fernet key (urlsafe base64, 32-byte payload)."
        ) from exc

    if len(decoded) != 32:
        raise RuntimeError(
            "Invalid CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY length. "
            "Expected a 32-byte Fernet key payload."
        )

    try:
        from cryptography.fernet import Fernet
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(
            "cryptography package is required for runtime secret encryption."
        ) from exc

    return Fernet(key_bytes)


def encode_secret(value: str) -> str:
    if not value:
        return value
    if is_encoded(value):
        return value

    fernet = _fernet_for_settings()
    token = fernet.encrypt(value.encode("utf-8")).decode("utf-8")
    return f"{ENC_PREFIX}{token}"


def decode_secret(value: str) -> str:
    if not value:
        return value
    if not is_encoded(value):
        return value

    fernet = _fernet_for_settings()
    token = value[len(ENC_PREFIX):]
    try:
        return fernet.decrypt(token.encode("utf-8")).decode("utf-8")
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError("Failed to decode encrypted runtime setting value.") from exc
