from __future__ import annotations

import uuid
from datetime import UTC, datetime

from ccs_platform.adapters.storage.base import StorageAdapter, StoredObject
from ccs_platform.core.settings import PlatformSettings


class GCSStorageAdapter(StorageAdapter):
    backend_name = "gcs"

    def __init__(self, settings: PlatformSettings) -> None:
        self.settings = settings
        try:
            from google.cloud import storage
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(
                "google-cloud-storage is required for GCS storage backend"
            ) from exc

        if not settings.gcs_bucket:
            raise RuntimeError("CCS_PLATFORM_GCS_BUCKET is required for gcs storage backend")

        credentials_file = settings.gcs_credentials_file
        if credentials_file:
            if not credentials_file.exists():
                raise RuntimeError(
                    "CCS_PLATFORM_GCS_CREDENTIALS_FILE points to a non-existent file"
                )
            self.client = storage.Client.from_service_account_json(
                str(credentials_file),
                project=settings.gcs_project,
            )
        else:
            self.client = storage.Client(project=settings.gcs_project)

        self.bucket = settings.gcs_bucket
        self.bucket_ref = self.client.bucket(self.bucket)

    def _save(
        self,
        *,
        content: bytes,
        folder: str,
        filename: str,
        profile_key: str | None = None,
        content_type: str = "application/octet-stream",
    ) -> StoredObject:
        ts = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
        safe_name = filename.replace("/", "_").replace("\\", "_")
        normalized_folder = folder.strip("/").strip()
        scoped_folder = normalized_folder
        if profile_key:
            scoped_folder = profile_key.strip()
            if normalized_folder:
                scoped_folder = f"{scoped_folder}/{normalized_folder}"
        key_prefix = f"{scoped_folder}/" if scoped_folder else ""
        key = f"{key_prefix}{ts}_{uuid.uuid4().hex}_{safe_name}"
        blob = self.bucket_ref.blob(key)
        blob.upload_from_string(content, content_type=content_type)
        return StoredObject(backend=self.backend_name, key=key)

    def save_pdf(
        self,
        *,
        content: bytes,
        filename: str,
        source: str,
        profile_key: str | None = None,
    ) -> StoredObject:
        source_prefix = (source or "pdf").strip().lower()
        return self._save(
            content=content,
            folder="",
            filename=f"{source_prefix}_{filename}",
            profile_key=profile_key,
            content_type="application/pdf",
        )

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
        blob = self.bucket_ref.blob(key)
        return blob.download_as_bytes()

    def delete(self, key: str) -> None:
        self.bucket_ref.blob(key).delete()
