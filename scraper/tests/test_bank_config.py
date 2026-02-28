from __future__ import annotations

from pathlib import Path

import pytest

from scraper.banks.bank_config import AppConfig, Paths, default_paths, load_app_config

_EXPECTED_BANKS = {"FAB", "ADCB", "ENBD", "EIB", "SIB", "MASHREQ"}


def test_loads_all_expected_banks() -> None:
    config = load_app_config()
    assert set(config.banks.keys()) == _EXPECTED_BANKS


def test_returns_app_config_type() -> None:
    config = load_app_config()
    assert isinstance(config, AppConfig)
    assert isinstance(config.paths, Paths)


def test_each_bank_has_portal_url() -> None:
    config = load_app_config()
    for code, bank in config.banks.items():
        assert "portal_url" in bank, f"{code} missing portal_url"
        assert bank["portal_url"].startswith("https://"), f"{code} portal_url must be HTTPS"


def test_paths_derived_from_download_dir(tmp_path: Path) -> None:
    config = load_app_config(download_dir=tmp_path)
    p = config.paths
    assert p.data_dir == tmp_path
    assert p.incoming_dir == tmp_path / "incoming"
    assert p.archive_dir == tmp_path / "archive"
    assert p.output_dir == tmp_path / "output"
    assert p.state_dir == tmp_path / "state"


def test_default_paths_uses_downloads_subdir() -> None:
    paths = default_paths()
    # Default data dir is <repo>/scraper/downloads
    assert paths.data_dir.name == "downloads"
    assert paths.incoming_dir == paths.data_dir / "incoming"
    assert paths.state_dir == paths.data_dir / "state"


def test_config_dir_points_to_package_config() -> None:
    """config_dir is always the package's config/ regardless of download_dir."""
    paths = default_paths()
    assert (paths.config_dir / "banks.yaml").exists()
