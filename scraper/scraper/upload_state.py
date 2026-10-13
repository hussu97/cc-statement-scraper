"""Persistent record of PDFs that were successfully uploaded.

Stored as ``state/uploaded.json`` (sha256 → {filename, doc_code, status,
bank_code, uploaded_at}) so ``ccs-scraper upload-pending`` can skip files that
already reached the server.  Re-sending is still safe (the server dedupes by
sha256); this file only avoids needless uploads.  Writes are atomic and a
corrupt file is kept aside as ``uploaded.json.<timestamp>.corrupt``
(``scraper.json_state``).
"""
from __future__ import annotations

import hashlib
import re
from datetime import UTC, datetime
from pathlib import Path

from scraper.json_state import load_json_object, write_json_atomic


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


# Mirrors sanitizeFilename() in supabase/functions/_shared/documents.ts, whose result
# the server echoes back as ``uploads[].filename``.
_SERVER_FILENAME_MAX_UTF16_UNITS = 200
_CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]")
# JavaScript String.prototype.trim() whitespace; str.strip() differs (no U+FEFF, adds U+0085).
_JS_WHITESPACE = "\t\n\v\f\r \u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a" \
                 "\u2028\u2029\u202f\u205f\u3000\ufeff"


def server_filename(name: str) -> str:
    """The filename the upload function reports for a file sent as *name*.

    Last path segment, control characters removed, trimmed, then the last 200
    UTF-16 code units (JavaScript ``slice(-200)``); ``statement.pdf`` if empty.
    Matching on this instead of the raw name lets long or padded names be
    recorded in uploaded.json (audit SRV-16).
    """
    base = re.split(r"[\\/]", name)[-1]
    clean = _CONTROL_CHARS.sub("", base).strip(_JS_WHITESPACE)
    units = clean.encode("utf-16-le", "surrogatepass")
    limit = _SERVER_FILENAME_MAX_UTF16_UNITS * 2
    if len(units) > limit:
        clean = units[-limit:].decode("utf-16-le", "surrogatepass")
    return clean or "statement.pdf"


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
        # A corrupt file is moved aside to uploaded.json.<ts>.corrupt with a warning (SRV-16).
        return load_json_object(self._path)

    def _save(self, data: dict[str, dict]) -> None:
        write_json_atomic(self._path, data, sort_keys=True)
