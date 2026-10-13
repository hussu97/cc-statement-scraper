"""Persistent mapping of downloaded PDF paths to the bank that produced them.

The map is stored as a JSON file in the scraper state directory so it survives
process restarts.  Entries are kept after upload so ``ccs-scraper
upload-pending`` can re-send a PDF with its bank hint; which files already
reached the server is tracked separately in ``state/uploaded.json``
(see ``scraper.upload_state``).
"""
from __future__ import annotations

from pathlib import Path

from scraper.json_state import load_json_object, write_json_atomic


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
        """Remove entries for *pdf_paths* (e.g. when the PDFs are deleted)."""
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
        # Atomic writes; a corrupt file is kept aside with a warning (SRV-16).
        return load_json_object(self._path)

    def _save(self, data: dict[str, str]) -> None:
        write_json_atomic(self._path, data)
