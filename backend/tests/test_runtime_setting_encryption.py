from __future__ import annotations

import pytest

from ccs_platform.core.runtime_settings import decode_runtime_setting_value, encode_runtime_setting_value
from ccs_platform.core.settings import clear_settings_caches


def test_secret_value_is_plain_without_encryption_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY", raising=False)
    clear_settings_caches()

    try:
        plain = encode_runtime_setting_value(value="sensitive", is_secret=True)
        assert plain == "sensitive"
        decoded = decode_runtime_setting_value(value=plain, is_secret=True)
        assert decoded == "sensitive"
    finally:
        clear_settings_caches()


def test_secret_value_roundtrip_with_encryption_key(monkeypatch: pytest.MonkeyPatch) -> None:
    pytest.importorskip("cryptography", reason="cryptography not installed")
    monkeypatch.setenv("CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY", "V33IhV4J0EAOQnq2STxwJK6I2Gv5u9W1tnM0B8f9Lh4=")
    clear_settings_caches()

    try:
        encoded = encode_runtime_setting_value(value="very-secret", is_secret=True)
        assert encoded.startswith("enc:v1:")

        decoded = decode_runtime_setting_value(value=encoded, is_secret=True)
        assert decoded == "very-secret"
    finally:
        clear_settings_caches()


def test_secret_value_requires_encryption_key_in_production(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CCS_PLATFORM_ENVIRONMENT", "production")
    monkeypatch.setenv("CCS_PLATFORM_SESSION_SECRET_KEY", "test-secret-key-long-enough-for-production-x")
    monkeypatch.setenv("CCS_PLATFORM_CORS_ALLOW_ORIGINS", "https://app.example.com")
    monkeypatch.delenv("CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY", raising=False)
    clear_settings_caches()

    try:
        with pytest.raises(RuntimeError, match="encryption is required"):
            encode_runtime_setting_value(value="prod-secret", is_secret=True)
    finally:
        clear_settings_caches()


def test_decode_encrypted_secret_without_key_in_development_returns_blank(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    pytest.importorskip("cryptography", reason="cryptography not installed")
    monkeypatch.setenv("CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY", "V33IhV4J0EAOQnq2STxwJK6I2Gv5u9W1tnM0B8f9Lh4=")
    monkeypatch.setenv("CCS_PLATFORM_ENVIRONMENT", "development")
    clear_settings_caches()

    try:
        encoded = encode_runtime_setting_value(value="legacy-secret", is_secret=True)
    finally:
        monkeypatch.delenv("CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY", raising=False)
        clear_settings_caches()

    try:
        decoded = decode_runtime_setting_value(value=encoded, is_secret=True)
        assert decoded == ""
    finally:
        clear_settings_caches()
