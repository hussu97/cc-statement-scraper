from __future__ import annotations

from pathlib import Path

import pytest

from scraper.config import ScraperConfig, get_config

_SCRAPER_KEYS = [
    "CCS_SCRAPER_TARGET_URL",
    "CCS_SCRAPER_API_TOKEN",
    "CCS_SCRAPER_HEADLESS",
    "CCS_SCRAPER_BROWSER_PROXY_URL",
    "CCS_SCRAPER_BROWSER_GEO_LATITUDE",
    "CCS_SCRAPER_BROWSER_GEO_LONGITUDE",
    "CCS_SCRAPER_BROWSER_TIMEZONE_ID",
    "CCS_SCRAPER_BROWSER_LOCALE",
    "CCS_SCRAPER_DOWNLOAD_DIR",
]

_CREDENTIAL_KEYS = [
    "FAB_USERNAME", "FAB_PASSWORD",
    "ADCB_CID", "ADCB_LOGIN_PASSWORD", "ADCB_PDF_PASSWORD",
    "ENBD_USERNAME", "ENBD_PASSWORD",
    "EIB_USERNAME", "EIB_PASSWORD",
    "SIB_USER_ID", "SIB_PASSWORD", "SIB_PDF_PASSWORD",
    "MASHREQ_USERNAME", "MASHREQ_PASSWORD",
]


def _clear_scraper_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in _SCRAPER_KEYS + _CREDENTIAL_KEYS:
        monkeypatch.delenv(key, raising=False)
    # Also clear profile-prefixed variants used by the new multi-profile format.
    for profile in ("HUSSAIN", "TEJASVIE"):
        for key in _CREDENTIAL_KEYS:
            monkeypatch.delenv(f"{profile}_{key}", raising=False)


def test_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear_scraper_env(monkeypatch)
    cfg = ScraperConfig()
    assert cfg.target_url == "http://127.0.0.1:8000"
    assert cfg.api_token == ""
    assert cfg.profile_key == ""
    assert cfg.headless is True
    assert cfg.browser_proxy_url is None
    assert cfg.browser_geo_latitude == 25.2048
    assert cfg.browser_geo_longitude == 55.2708
    assert cfg.browser_timezone_id == "Asia/Dubai"
    assert cfg.browser_locale == "en-AE"
    assert isinstance(cfg.download_dir, Path)


def test_env_overrides(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CCS_SCRAPER_TARGET_URL", "https://api.example.com")
    monkeypatch.setenv("CCS_SCRAPER_API_TOKEN", "tok_abc")
    monkeypatch.setenv("CCS_SCRAPER_HEADLESS", "false")
    monkeypatch.setenv("CCS_SCRAPER_BROWSER_PROXY_URL", "socks5://127.0.0.1:1080")
    monkeypatch.setenv("CCS_SCRAPER_BROWSER_GEO_LATITUDE", "24.0")
    monkeypatch.setenv("CCS_SCRAPER_BROWSER_GEO_LONGITUDE", "54.0")
    monkeypatch.setenv("CCS_SCRAPER_BROWSER_TIMEZONE_ID", "UTC")
    monkeypatch.setenv("CCS_SCRAPER_BROWSER_LOCALE", "en-US")

    cfg = ScraperConfig()
    assert cfg.target_url == "https://api.example.com"
    assert cfg.api_token == "tok_abc"
    assert cfg.headless is False
    assert cfg.browser_proxy_url == "socks5://127.0.0.1:1080"
    assert cfg.browser_geo_latitude == 24.0
    assert cfg.browser_geo_longitude == 54.0
    assert cfg.browser_timezone_id == "UTC"
    assert cfg.browser_locale == "en-US"


@pytest.mark.parametrize("value", ["false", "False", "FALSE"])
def test_headless_false_variants(monkeypatch: pytest.MonkeyPatch, value: str) -> None:
    monkeypatch.setenv("CCS_SCRAPER_HEADLESS", value)
    assert ScraperConfig().headless is False


@pytest.mark.parametrize("value", ["true", "True", "1", "yes", ""])
def test_headless_truthy_variants(monkeypatch: pytest.MonkeyPatch, value: str) -> None:
    monkeypatch.setenv("CCS_SCRAPER_HEADLESS", value)
    assert ScraperConfig().headless is True


def test_proxy_url_none_when_blank(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CCS_SCRAPER_BROWSER_PROXY_URL", "")
    assert ScraperConfig().browser_proxy_url is None


def test_download_dir_is_path(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CCS_SCRAPER_DOWNLOAD_DIR", "/tmp/test_downloads")
    cfg = ScraperConfig()
    assert isinstance(cfg.download_dir, Path)
    assert str(cfg.download_dir) == "/tmp/test_downloads"


def test_credentials_populated_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear_scraper_env(monkeypatch)
    monkeypatch.setenv("CCS_SCRAPER_API_TOKEN", "test-token")
    monkeypatch.setenv("HUSSAIN_FAB_USERNAME", "myuser")
    monkeypatch.setenv("HUSSAIN_FAB_PASSWORD", "mypass")

    cfg = get_config(profile="hussain")
    assert cfg.credentials["FAB_USERNAME"] == "myuser"
    assert cfg.credentials["FAB_PASSWORD"] == "mypass"


def test_credentials_all_known_keys(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear_scraper_env(monkeypatch)
    monkeypatch.setenv("CCS_SCRAPER_API_TOKEN", "test-token")
    for key in _CREDENTIAL_KEYS:
        monkeypatch.setenv(f"HUSSAIN_{key}", f"value_{key}")

    cfg = get_config(profile="hussain")
    for key in _CREDENTIAL_KEYS:
        assert key in cfg.credentials, f"{key} should be in credentials"


def test_credentials_blank_values_excluded(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HUSSAIN_FAB_USERNAME", "")
    monkeypatch.setenv("HUSSAIN_FAB_PASSWORD", "secret")

    cfg = get_config(profile="hussain")
    assert "FAB_USERNAME" not in cfg.credentials
    assert cfg.credentials.get("FAB_PASSWORD") == "secret"


def test_credentials_unrecognised_keys_excluded(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("RANDOM_KEY", "value")
    monkeypatch.setenv("PATH", "/usr/bin")

    cfg = ScraperConfig()
    assert "RANDOM_KEY" not in cfg.credentials
    assert "PATH" not in cfg.credentials


def test_get_config_profile_override(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear_scraper_env(monkeypatch)
    monkeypatch.setenv("CCS_SCRAPER_API_TOKEN", "test-token")
    monkeypatch.setenv("TEJASVIE_FAB_USERNAME", "tej_user")
    monkeypatch.setenv("HUSSAIN_FAB_USERNAME", "hussain_user")

    cfg = get_config(profile="tejasvie")
    assert cfg.profile_key == "tejasvie"
    assert cfg.credentials["FAB_USERNAME"] == "tej_user"


def test_credentials_profile_isolation(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear_scraper_env(monkeypatch)
    monkeypatch.setenv("CCS_SCRAPER_API_TOKEN", "test-token")
    monkeypatch.setenv("HUSSAIN_FAB_USERNAME", "hussain_user")
    monkeypatch.setenv("TEJASVIE_FAB_USERNAME", "tej_user")

    hussain_cfg = get_config(profile="hussain")
    tejasvie_cfg = get_config(profile="tejasvie")
    assert hussain_cfg.credentials["FAB_USERNAME"] == "hussain_user"
    assert tejasvie_cfg.credentials["FAB_USERNAME"] == "tej_user"
