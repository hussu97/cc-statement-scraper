"""Persistent mapping of downloaded PDF paths to the bank that produced them.

The map is stored as a JSON file in the scraper state directory so it survives
process restarts.  Entries are removed after a successful upload so the file
stays small and only represents PDFs that are pending upload.
"""
from __future__ import annotations

import json
from pathlib import Path


class BankMap:
    """Thread-unsafe single-process map: one scraper process at a time is assumed."""

    def __init__(self, state_dir: Path) -> None:
        self._path = state_dir / "bank_map.json"

    def record(self, pdf_path: Path, bank_code: str) -> None:
        """Record that *pdf_path* was downloaded from *bank_code*'s portal."""
        data = self._load()
        data[str(pdf_path.resolve())] = bank_code.upper()
        self._save(data)

    def get(self, pdf_path: Path) -> str | None:
        """Return the bank code for *pdf_path*, or None if not recorded."""
        return self._load().get(str(pdf_path.resolve()))

    def remove(self, pdf_paths: list[Path]) -> None:
        """Remove entries for *pdf_paths* once they have been successfully uploaded."""
        data = self._load()
        changed = False
        for p in pdf_paths:
            key = str(p.resolve())
            if key in data:
                del data[key]
                changed = True
        if changed:
            self._save(data)

    # ------------------------------------------------------------------
    def _load(self) -> dict[str, str]:
        if not self._path.exists():
            return {}
        try:
            return json.loads(self._path.read_text())
        except Exception:  # noqa: BLE001 — corrupt file, start fresh
            return {}

    def _save(self, data: dict[str, str]) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(json.dumps(data, indent=2))
