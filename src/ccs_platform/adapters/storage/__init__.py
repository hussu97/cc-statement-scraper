from ccs_platform.adapters.storage.base import StorageAdapter, StoredObject
from ccs_platform.adapters.storage.factory import build_storage_adapter
from ccs_platform.adapters.storage.local import LocalStorageAdapter
from ccs_platform.adapters.storage.s3 import S3StorageAdapter

__all__ = [
    "LocalStorageAdapter",
    "S3StorageAdapter",
    "StorageAdapter",
    "StoredObject",
    "build_storage_adapter",
]
