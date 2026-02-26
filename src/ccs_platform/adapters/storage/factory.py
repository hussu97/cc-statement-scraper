from __future__ import annotations

from ccs_platform.adapters.storage.base import StorageAdapter
from ccs_platform.adapters.storage.gcs import GCSStorageAdapter
from ccs_platform.adapters.storage.local import LocalStorageAdapter
from ccs_platform.core.settings import PlatformSettings


def build_storage_adapter(settings: PlatformSettings) -> StorageAdapter:
    backend = settings.storage_backend.strip().lower()
    if backend == "local":
        return LocalStorageAdapter(settings.local_storage_dir)
    if backend == "gcs":
        return GCSStorageAdapter(settings)
    raise RuntimeError(
        f"Unsupported storage backend '{settings.storage_backend}'. Expected one of: local, gcs."
    )
