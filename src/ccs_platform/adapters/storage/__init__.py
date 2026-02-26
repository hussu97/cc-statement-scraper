from ccs_platform.adapters.storage.base import StorageAdapter, StoredObject
from ccs_platform.adapters.storage.factory import build_storage_adapter
from ccs_platform.adapters.storage.gcs import GCSStorageAdapter
from ccs_platform.adapters.storage.local import LocalStorageAdapter

__all__ = [
    "GCSStorageAdapter",
    "LocalStorageAdapter",
    "StorageAdapter",
    "StoredObject",
    "build_storage_adapter",
]
