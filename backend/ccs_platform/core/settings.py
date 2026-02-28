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
    backups_dir: Path = ROOT_DIR / "data" / "backups"

    job_poll_interval_seconds: int = 5
    schedule_poll_interval_seconds: int = 30
    max_worker_threads: int = 1
    worker_max_active_jobs: int | None = None
    embedded_worker: bool = True
    worker_queues: str = "default,scrape"
    job_dispatch_backend: str = "database"
    job_retry_base_seconds: int = 30
    job_retry_jitter_seconds: int = 15
    job_retry_max_delay_seconds: int = 900
    job_heartbeat_interval_seconds: int = 15
    job_heartbeat_timeout_seconds: int = 1800
    queue_backlog_slo_default: int = 100
    queue_backlog_slo_scrape: int = 20
    queue_oldest_age_slo_seconds: int = 900
    retention_jobs_days: int = 90
    retention_exports_days: int = 90
    retention_audit_events_days: int = 365
    retention_logs_days: int = 30
    retention_uploads_days: int = 14
    retention_backups_days: int = 30

    cors_allow_origins: str = "*"
    log_level: str = "INFO"
    request_logging_enabled: bool = True
    request_id_header: str = "X-Request-ID"

    allow_legacy_sqlite_reset: bool | None = None
    require_login: bool = True
    session_cookie_name: str = "ccs_session"
    session_max_age_seconds: int = 1209600
    session_secret_key: str = "change-this-in-production"
    session_cookie_secure: bool | None = None
    rbac_enabled: bool | None = None

    runtime_settings_expose_secrets: bool | None = None
    runtime_settings_require_encryption: bool | None = None
    runtime_settings_encryption_key: str | None = None
    runtime_settings_seed_source: str | None = None
    runtime_settings_env_file: Path | None = ROOT_DIR / ".env"
    email_ingestion_enabled: bool = False

    def model_post_init(self, __context: object) -> None:
        if self.is_production():
            default_key = "change-this-in-production"
            if self.session_secret_key == default_key or len(self.session_secret_key.encode()) < 32:
                raise RuntimeError(
                    "CCS_PLATFORM_SESSION_SECRET_KEY is not configured for production. "
                    "Set it to a random string of at least 32 bytes before starting."
                )

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

    def login_required(self) -> bool:
        return bool(self.require_login)

    def session_cookie_is_secure(self) -> bool:
        if self.session_cookie_secure is None:
            return self.is_production()
        return self.session_cookie_secure

    def rbac_enforced(self) -> bool:
        if self.rbac_enabled is None:
            return self.is_production()
        return self.rbac_enabled

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

    def worker_queue_set(self) -> set[str]:
        tokens = {
            token.strip().lower()
            for token in self.worker_queues.split(",")
            if token.strip()
        }
        return tokens or {"default", "scrape"}

    def worker_active_job_limit(self) -> int:
        if self.worker_max_active_jobs is not None:
            return max(1, int(self.worker_max_active_jobs))
        return max(1, int(self.max_worker_threads))


@lru_cache(maxsize=1)
def get_settings() -> PlatformSettings:
    settings = PlatformSettings(_env_file=ROOT_DIR / ".env", _env_file_encoding="utf-8")
    settings.local_storage_dir.mkdir(parents=True, exist_ok=True)
    settings.uploads_temp_dir.mkdir(parents=True, exist_ok=True)
    settings.logs_dir.mkdir(parents=True, exist_ok=True)
    settings.backups_dir.mkdir(parents=True, exist_ok=True)
    return settings
