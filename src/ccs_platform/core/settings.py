from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


ROOT_DIR = Path(__file__).resolve().parents[3]


class PlatformSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CCS_PLATFORM_", extra="ignore")

    app_name: str = "CCS Platform API"
    api_prefix: str = "/api/v1"
    environment: str = "development"
    database_url: str = Field(
        default=f"sqlite:///{ROOT_DIR / 'data' / 'state' / 'platform.db'}"
    )
    timezone: str = "Asia/Dubai"

    storage_backend: str = "local"
    local_storage_dir: Path = ROOT_DIR / "data" / "archive"

    gcs_bucket: str | None = None
    gcs_project: str | None = None
    gcs_credentials_file: Path | None = None

    uploads_temp_dir: Path = ROOT_DIR / "data" / "incoming"
    logs_dir: Path = ROOT_DIR / "logs"

    job_poll_interval_seconds: int = 5
    schedule_poll_interval_seconds: int = 30
    max_worker_threads: int = 1
    embedded_worker: bool = True
    job_dispatch_backend: str = "database"
    job_retry_base_seconds: int = 30
    job_retry_jitter_seconds: int = 15
    job_retry_max_delay_seconds: int = 900

    cors_allow_origins: str = "*"
    log_level: str = "INFO"
    request_logging_enabled: bool = True
    request_id_header: str = "X-Request-ID"

    allow_legacy_sqlite_reset: bool | None = None
    require_api_auth: bool | None = None
    api_auth_token: str | None = None
    api_auth_exempt_paths: str = "/api/v1/health,/api/v1/health/ready"

    runtime_settings_expose_secrets: bool | None = None
    runtime_settings_require_encryption: bool | None = None
    runtime_settings_encryption_key: str | None = None
    runtime_settings_seed_source: str | None = None
    runtime_settings_env_file: Path | None = ROOT_DIR / ".env"

    def is_production(self) -> bool:
        normalized = self.environment.strip().lower()
        return normalized in {"prod", "production"}

    def resolved_database_url(self) -> str:
        url = (self.database_url or "").strip()
        if url.startswith("postgres://"):
            return f"postgresql+psycopg://{url[len('postgres://'):]}"
        if url.startswith("postgresql://"):
            return f"postgresql+psycopg://{url[len('postgresql://'):]}"
        return url

    def sqlite_legacy_reset_enabled(self) -> bool:
        if self.allow_legacy_sqlite_reset is None:
            return not self.is_production()
        return self.allow_legacy_sqlite_reset

    def api_auth_enabled(self) -> bool:
        if self.require_api_auth is None:
            return self.is_production()
        return self.require_api_auth

    def api_auth_exempt_path_set(self) -> set[str]:
        paths = {path.strip() for path in self.api_auth_exempt_paths.split(",") if path.strip()}
        return paths or {f"{self.api_prefix}/health"}

    def secret_value_readback_enabled(self) -> bool:
        if self.runtime_settings_expose_secrets is None:
            return not self.is_production()
        return self.runtime_settings_expose_secrets

    def runtime_settings_encryption_required(self) -> bool:
        if self.runtime_settings_require_encryption is None:
            return self.is_production()
        return self.runtime_settings_require_encryption

    def runtime_settings_seed_source_mode(self) -> str:
        raw = (self.runtime_settings_seed_source or "").strip().lower()
        if raw:
            return raw
        return "env" if self.is_production() else "env_file_then_env"


@lru_cache(maxsize=1)
def get_settings() -> PlatformSettings:
    settings = PlatformSettings()
    settings.local_storage_dir.mkdir(parents=True, exist_ok=True)
    settings.uploads_temp_dir.mkdir(parents=True, exist_ok=True)
    settings.logs_dir.mkdir(parents=True, exist_ok=True)
    return settings
