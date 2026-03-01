from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

_ROOT = Path(__file__).resolve().parents[1]
_ENV_FILE = _ROOT / ".env"
if _ENV_FILE.exists():
    load_dotenv(_ENV_FILE, override=False)


@dataclass
class ScraperConfig:
    # Backend API
    target_url: str = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_TARGET_URL", "http://127.0.0.1:8000"))
    api_token: str = field(default_factory=lambda: os.environ.get("CCS_SCRAPER_API_TOKEN", ""))
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


def get_config(profile: str) -> ScraperConfig:
    cfg = ScraperConfig()
    cfg.profile_key = profile
    # Scope the download directory to the profile so that different profiles
    # never share incoming/, state/, or browser_profiles/ folders.
    cfg.download_dir = cfg.download_dir / profile.lower()
    cfg._reload_credentials()
    return cfg
