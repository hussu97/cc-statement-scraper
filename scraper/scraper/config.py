from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

_ROOT = Path(__file__).resolve().parents[1]

# Legacy FastAPI backend upload route. Ledger v2 (Supabase Edge Function) uses
# ``/functions/v1/statements-upload`` with CCS_SCRAPER_TARGET_URL=<SUPABASE_URL>.
DEFAULT_TARGET_URL = "http://127.0.0.1:8040"
DEFAULT_UPLOAD_PATH = "/api/v1/jobs/upload"
_ENV_FILE = _ROOT / ".env"
if _ENV_FILE.exists():
    load_dotenv(_ENV_FILE, override=False)


@dataclass
class ScraperConfig:
    # Backend API
    target_url: str = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_TARGET_URL") or DEFAULT_TARGET_URL)
    upload_path: str = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_UPLOAD_PATH") or DEFAULT_UPLOAD_PATH)
    api_token: str = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_API_TOKEN", ""))
    # Optional Supabase anon/publishable key, sent as the ``apikey`` header when set.
    supabase_anon_key: str | None = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_SUPABASE_ANON_KEY") or None)
    profile_key: str = field(default="")

    # Browser settings
    headless: bool = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_HEADLESS", "true").lower() != "false")
    browser_proxy_url: str | None = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_BROWSER_PROXY_URL") or None)
    browser_geo_latitude: float = field(default_factory=lambda: float(os.environ.get("CCS_SCRAPER_BROWSER_GEO_LATITUDE", "25.2048")))
    browser_geo_longitude: float = field(default_factory=lambda: float(os.environ.get("CCS_SCRAPER_BROWSER_GEO_LONGITUDE", "55.2708")))
    browser_timezone_id: str = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_BROWSER_TIMEZONE_ID", "Asia/Dubai"))
    browser_locale: str = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_BROWSER_LOCALE", "en-AE"))

    # Download directory
    download_dir: Path = field(default_factory=lambda: Path(os.environ.get("CCS_SCRAPER_DOWNLOAD_DIR", "./downloads")))

    # Bank credentials sourced from env (keyed without profile prefix)
    credentials: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.download_dir = Path(self.download_dir)
        self._reload_credentials()

    def _reload_credentials(self) -> None:
        """Re-read credentials for the current profile_key from the environment."""
        prefix = self.profile_key.upper() + "_"
        credential_keys = {
            "FAB_USERNAME", "FAB_PASSWORD",
            "ADCB_CID", "ADCB_LOGIN_PASSWORD", "ADCB_PDF_PASSWORD",
            "ENBD_USERNAME", "ENBD_PASSWORD",
            "EIB_USERNAME", "EIB_PASSWORD",
            "SIB_USER_ID", "SIB_PASSWORD", "SIB_PDF_PASSWORD",
            "MASHREQ_USERNAME", "MASHREQ_PASSWORD",
        }
        self.credentials = {
            k[len(prefix):]: v
            for k, v in os.environ.items()
            if k.startswith(prefix) and k[len(prefix):] in credential_keys and v
        }


def profile_token_env(profile: str) -> str:
    """Env var holding the profile's own service token, e.g. ``ALICE_CCS_SCRAPER_API_TOKEN``.

    Ledger v2 service tokens belong to exactly one profile, so each profile needs its own.
    Namespaced like the bank credentials (``<PROFILE>_FAB_USERNAME``).
    """
    return f"{profile.upper()}_CCS_SCRAPER_API_TOKEN"


def resolve_api_token(profile: str) -> str:
    """``<PROFILE>_CCS_SCRAPER_API_TOKEN`` if set, else the global ``CCS_SCRAPER_API_TOKEN``."""
    return os.environ.get(profile_token_env(profile)) or os.environ.get("CCS_SCRAPER_API_TOKEN", "")


def get_config(profile: str) -> ScraperConfig:
    cfg = ScraperConfig()
    cfg.profile_key = profile
    # Scope the download directory to the profile so that different profiles
    # never share incoming/, state/, or browser_profiles/ folders.
    cfg.download_dir = cfg.download_dir / profile.lower()
    cfg._reload_credentials()
    cfg.api_token = resolve_api_token(profile)
    if not cfg.api_token:
        raise RuntimeError(
            f"No API token for profile {profile!r}: set {profile_token_env(profile)} "
            "(or the global CCS_SCRAPER_API_TOKEN) in scraper/.env or export it before running."
        )
    return cfg
