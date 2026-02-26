from __future__ import annotations

import uuid
from datetime import UTC, datetime
from pathlib import Path

from ccs_platform.adapters.storage.base import StorageAdapter, StoredObject


class LocalStorageAdapter(StorageAdapter):
    backend_name = "local"

    def __init__(self, root_dir: Path) -> None:
        self.root_dir = root_dir
        self.root_dir.mkdir(parents=True, exist_ok=True)

    def _save(
        self,
        *,
        content: bytes,
        folder: str,
        filename: str,
        profile_key: str | None = None,
    ) -> StoredObject:
        ts = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
        safe_name = filename.replace("/", "_").replace("\\", "_")
        scoped_folder = folder
        if profile_key:
            scoped_folder = f"profiles/{profile_key}/{folder}"
        key = f"{scoped_folder}/{ts}_{uuid.uuid4().hex}_{safe_name}"
        full_path = self.root_dir / key
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_bytes(content)
        return StoredObject(backend=self.backend_name, key=key)

    def save_pdf(
        self,
        *,
        content: bytes,
        filename: str,
        source: str,
        profile_key: str | None = None,
    ) -> StoredObject:
        folder = f"pdf/{source}"
        return self._save(content=content, folder=folder, filename=filename, profile_key=profile_key)

    def save_binary(
        self,
        *,
        content: bytes,
        filename: str,
        folder: str,
        profile_key: str | None = None,
    ) -> StoredObject:
        return self._save(content=content, folder=folder, filename=filename, profile_key=profile_key)

    def read_bytes(self, key: str) -> bytes:
        return (self.root_dir / key).read_bytes()
