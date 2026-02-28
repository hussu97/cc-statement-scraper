from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


@dataclass
class Paths:
    root: Path
    config_dir: Path
    data_dir: Path
    incoming_dir: Path
    archive_dir: Path
    output_dir: Path
    state_dir: Path


@dataclass
class AppConfig:
    banks: dict[str, dict[str, Any]]
    paths: Paths


_ROOT = Path(__file__).resolve().parents[2]


def default_paths(download_dir: Path | None = None) -> Paths:
    data_dir = download_dir or (_ROOT / "downloads")
    return Paths(
        root=_ROOT,
        config_dir=_ROOT / "config",
        data_dir=data_dir,
        incoming_dir=data_dir / "incoming",
        archive_dir=data_dir / "archive",
        output_dir=data_dir / "output",
        state_dir=data_dir / "state",
    )


def load_app_config(download_dir: Path | None = None) -> AppConfig:
    paths = default_paths(download_dir)
    config_file = paths.config_dir / "banks.yaml"
    with config_file.open("r", encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    return AppConfig(
        banks=doc.get("banks", {}),
        paths=paths,
    )
