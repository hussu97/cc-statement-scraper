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
    database_url: str = Field(
        default=f"sqlite:///{ROOT_DIR / 'data' / 'state' / 'platform.db'}"
    )
    timezone: str = "Asia/Dubai"

    storage_backend: str = "local"
    local_storage_dir: Path = ROOT_DIR / "data" / "archive" / "platform"

    s3_endpoint_url: str | None = None
    s3_region: str | None = None
    s3_bucket: str | None = None
    s3_access_key_id: str | None = None
    s3_secret_access_key: str | None = None

    uploads_temp_dir: Path = ROOT_DIR / "data" / "incoming"
    logs_dir: Path = ROOT_DIR / "logs"

    job_poll_interval_seconds: int = 5
    schedule_poll_interval_seconds: int = 30
    max_worker_threads: int = 2
    embedded_worker: bool = True

    cors_allow_origins: str = "*"


@lru_cache(maxsize=1)
def get_settings() -> PlatformSettings:
    settings = PlatformSettings()
    settings.local_storage_dir.mkdir(parents=True, exist_ok=True)
    settings.uploads_temp_dir.mkdir(parents=True, exist_ok=True)
    settings.logs_dir.mkdir(parents=True, exist_ok=True)
    return settings
