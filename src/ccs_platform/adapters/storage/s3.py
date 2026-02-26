from __future__ import annotations

import io
import uuid
from datetime import UTC, datetime

from ccs_platform.adapters.storage.base import StorageAdapter, StoredObject
from ccs_platform.core.settings import PlatformSettings


class S3StorageAdapter(StorageAdapter):
    backend_name = "s3"

    def __init__(self, settings: PlatformSettings) -> None:
        self.settings = settings
        try:
            import boto3
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError("boto3 is required for S3 storage backend") from exc

        if not settings.s3_bucket:
            raise RuntimeError("CCS_PLATFORM_S3_BUCKET is required for s3 storage backend")

        self.bucket = settings.s3_bucket
        self.client = boto3.client(
            "s3",
            endpoint_url=settings.s3_endpoint_url,
            region_name=settings.s3_region,
            aws_access_key_id=settings.s3_access_key_id,
            aws_secret_access_key=settings.s3_secret_access_key,
        )

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
        normalized_folder = folder.strip("/").strip()
        scoped_folder = normalized_folder
        if profile_key:
            scoped_folder = profile_key.strip()
            if normalized_folder:
                scoped_folder = f"{scoped_folder}/{normalized_folder}"
        key_prefix = f"{scoped_folder}/" if scoped_folder else ""
        key = f"{key_prefix}{ts}_{uuid.uuid4().hex}_{safe_name}"
        self.client.upload_fileobj(io.BytesIO(content), self.bucket, key)
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
        obj = self.client.get_object(Bucket=self.bucket, Key=key)
        return obj["Body"].read()
