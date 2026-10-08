"""Persistent record of PDFs that were successfully uploaded.

Stored as ``state/uploaded.json`` (sha256 → {filename, doc_code, status,
bank_code, uploaded_at}) so ``ccs-scraper upload-pending`` can skip files that
already reached the server.  Re-sending is still safe (the server dedupes by
sha256); this file only avoids needless uploads.
"""
from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class UploadedState:
    """Thread-unsafe single-process store: one scraper process at a time is assumed."""

    def __init__(self, state_dir: Path) -> None:
        self._path = state_dir / "uploaded.json"

    def get(self, sha256: str) -> dict | None:
        return self._load().get(sha256)

    def is_uploaded(self, sha256: str) -> bool:
        return sha256 in self._load()

    def record_many(self, entries: dict[str, dict]) -> None:
        """Record *entries* (sha256 → info) in a single write."""
        if not entries:
            return
        data = self._load()
        now = datetime.now(UTC).isoformat()
        for sha, info in entries.items():
            data[sha] = {**info, "uploaded_at": now}
        self._save(data)

    # ------------------------------------------------------------------
    def _load(self) -> dict[str, dict]:
        if not self._path.exists():
            return {}
        try:
            data = json.loads(self._path.read_text())
        except Exception:  # noqa: BLE001 — corrupt file, start fresh
            return {}
        return data if isinstance(data, dict) else {}

    def _save(self, data: dict[str, dict]) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(json.dumps(data, indent=2, sort_keys=True))
