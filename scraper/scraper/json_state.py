"""Crash-safe JSON files for the scraper's ``state/`` directory (audit SRV-16).

Writes go to a temp file in the same directory and are swapped in with
``os.replace``, so an interrupted write leaves the previous file intact. A file
that does not parse is moved aside to ``<name>.<timestamp>.corrupt`` with a
warning instead of being silently treated as empty and overwritten.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
from datetime import UTC, datetime
from pathlib import Path

logger = logging.getLogger("ccs_scraper.state")


def load_json_object(path: Path) -> dict:
    """Return the JSON object stored at *path*, or ``{}`` when it is missing.

    An unreadable or non-object file is quarantined (renamed to a timestamped
    ``.corrupt`` copy) and logged, then treated as empty.
    """
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        _quarantine(path, f"unreadable JSON ({exc})")
        return {}
    if not isinstance(data, dict):
        _quarantine(path, f"expected a JSON object, found {type(data).__name__}")
        return {}
    return data


def write_json_atomic(path: Path, data: dict, *, sort_keys: bool = False) -> None:
    """Write *data* to *path* atomically (temp file in the same directory + ``os.replace``)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2, sort_keys=sort_keys)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise


def _quarantine(path: Path, reason: str) -> None:
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    target = path.with_name(f"{path.name}.{stamp}.corrupt")
    try:
        os.replace(path, target)
    except OSError as exc:
        logger.warning("%s is corrupt (%s) and could not be moved aside: %s; treating it as empty",
                       path, reason, exc)
        return
    logger.warning("%s is corrupt (%s); kept a copy at %s and starting from an empty state",
                   path, reason, target.name)
