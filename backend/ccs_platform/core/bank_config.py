from __future__ import annotations

from dataclasses import dataclass
import os
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
    downloads_dir: Path


@dataclass
class AppConfig:
    banks: dict[str, dict[str, Any]]
    category_rules: dict[str, Any]
    paths: Paths


ROOT_DIR = Path(__file__).resolve().parents[2]


def default_paths() -> Paths:
    downloads_default = Path(
        os.getenv("CCS_DOWNLOADS_DIR", str(Path.home() / "Downloads"))
    )
    return Paths(
        root=ROOT_DIR,
        config_dir=ROOT_DIR / "config",
        data_dir=ROOT_DIR / "data",
        incoming_dir=ROOT_DIR / "data" / "incoming",
        archive_dir=ROOT_DIR / "data" / "archive",
        output_dir=ROOT_DIR / "data" / "output",
        state_dir=ROOT_DIR / "data" / "state",
        downloads_dir=downloads_default,
    )


def ensure_dirs(paths: Paths) -> None:
    for path in [
        paths.config_dir,
        paths.data_dir,
        paths.incoming_dir,
        paths.archive_dir,
        paths.output_dir,
        paths.state_dir,
    ]:
        path.mkdir(parents=True, exist_ok=True)


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def load_app_config() -> AppConfig:
    paths = default_paths()
    ensure_dirs(paths)

    banks_doc = load_yaml(paths.config_dir / "banks.yaml")
    rules_doc = load_yaml(paths.config_dir / "category_rules.yaml")
    return AppConfig(
        banks=banks_doc.get("banks", {}),
        category_rules=rules_doc,
        paths=paths,
    )
