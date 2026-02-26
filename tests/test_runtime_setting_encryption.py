from __future__ import annotations

import pytest

from ccs_platform.core import secret_codec
from ccs_platform.core.runtime_settings import decode_runtime_setting_value, encode_runtime_setting_value
from ccs_platform.core.settings import get_settings


def test_secret_value_is_plain_without_encryption_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY", raising=False)
    get_settings.cache_clear()
    secret_codec._fernet_for_settings.cache_clear()  # type: ignore[attr-defined]

    try:
        plain = encode_runtime_setting_value(value="sensitive", is_secret=True)
        assert plain == "sensitive"
        decoded = decode_runtime_setting_value(value=plain, is_secret=True)
        assert decoded == "sensitive"
    finally:
        get_settings.cache_clear()
        secret_codec._fernet_for_settings.cache_clear()  # type: ignore[attr-defined]


def test_secret_value_roundtrip_with_encryption_key(monkeypatch: pytest.MonkeyPatch) -> None:
    pytest.importorskip("cryptography", reason="cryptography not installed")
    monkeypatch.setenv("CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY", "V33IhV4J0EAOQnq2STxwJK6I2Gv5u9W1tnM0B8f9Lh4=")
    get_settings.cache_clear()
    secret_codec._fernet_for_settings.cache_clear()  # type: ignore[attr-defined]

    try:
        encoded = encode_runtime_setting_value(value="very-secret", is_secret=True)
        assert encoded.startswith("enc:v1:")

        decoded = decode_runtime_setting_value(value=encoded, is_secret=True)
        assert decoded == "very-secret"
    finally:
        get_settings.cache_clear()
        secret_codec._fernet_for_settings.cache_clear()  # type: ignore[attr-defined]


def test_secret_value_requires_encryption_key_in_production(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CCS_PLATFORM_ENVIRONMENT", "production")
    monkeypatch.delenv("CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY", raising=False)
    get_settings.cache_clear()
    secret_codec._fernet_for_settings.cache_clear()  # type: ignore[attr-defined]

    try:
        with pytest.raises(RuntimeError, match="encryption is required"):
            encode_runtime_setting_value(value="prod-secret", is_secret=True)
    finally:
        get_settings.cache_clear()
        secret_codec._fernet_for_settings.cache_clear()  # type: ignore[attr-defined]
