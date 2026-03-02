from __future__ import annotations

from ccs_platform.core.settings import PlatformSettings


def test_production_defaults_require_login_and_disable_legacy_reset() -> None:
    settings = PlatformSettings(
        environment="production",
        session_secret_key="test-secret-key-long-enough-for-production-x",
        cors_allow_origins="https://app.example.com",
        require_login=True,
        allow_legacy_sqlite_reset=None,
        runtime_settings_expose_secrets=None,
        runtime_settings_require_encryption=None,
        runtime_settings_seed_source=None,
    )

    assert settings.is_production() is True
    assert settings.login_required() is True
    assert settings.sqlite_legacy_reset_enabled() is False
    assert settings.secret_value_readback_enabled() is False
    assert settings.runtime_settings_encryption_required() is True
    assert settings.runtime_settings_seed_source_mode() == "env"
    assert settings.worker_queue_set() == {"default"}


def test_development_defaults_keep_local_compatibility() -> None:
    settings = PlatformSettings(
        environment="development",
        require_login=True,
        allow_legacy_sqlite_reset=None,
        runtime_settings_expose_secrets=None,
        runtime_settings_require_encryption=None,
        runtime_settings_seed_source=None,
    )

    assert settings.is_production() is False
    assert settings.login_required() is True
    assert settings.sqlite_legacy_reset_enabled() is True
    assert settings.secret_value_readback_enabled() is True
    assert settings.runtime_settings_encryption_required() is False
    assert settings.runtime_settings_seed_source_mode() == "env_file_then_env"


def test_explicit_overrides_take_precedence() -> None:
    settings = PlatformSettings(
        environment="production",
        session_secret_key="test-secret-key-long-enough-for-production-x",
        cors_allow_origins="https://app.example.com",
        require_login=False,
        allow_legacy_sqlite_reset=True,
        runtime_settings_expose_secrets=True,
        runtime_settings_require_encryption=False,
        runtime_settings_seed_source="none",
        worker_queues="default, scrape",
    )

    assert settings.login_required() is False
    assert settings.sqlite_legacy_reset_enabled() is True
    assert settings.secret_value_readback_enabled() is True
    assert settings.runtime_settings_encryption_required() is False
    assert settings.runtime_settings_seed_source_mode() == "none"
    assert settings.worker_queue_set() == {"default", "scrape"}


def test_database_url_normalization_for_postgres_driver() -> None:
    settings = PlatformSettings(database_url="postgresql://user:pass@db-host:5432/ccs")
    assert settings.resolved_database_url() == "postgresql+psycopg://user:pass@db-host:5432/ccs"
