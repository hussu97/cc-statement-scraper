from __future__ import annotations

from ccs_platform.adapters.storage.base import StorageAdapter
from ccs_platform.adapters.storage.local import LocalStorageAdapter
from ccs_platform.adapters.storage.s3 import S3StorageAdapter
from ccs_platform.core.settings import PlatformSettings


def build_storage_adapter(settings: PlatformSettings) -> StorageAdapter:
    if settings.storage_backend.lower() == "s3":
        return S3StorageAdapter(settings)
    return LocalStorageAdapter(settings.local_storage_dir)
