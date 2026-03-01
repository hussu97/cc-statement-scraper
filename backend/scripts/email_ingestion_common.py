#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import json
import mimetypes
import os
from pathlib import Path
import re
import time
from typing import Any
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request


DEFAULT_TIMEOUT_SECONDS = 120
_RETRY_ATTEMPTS = 3
_RETRY_BACKOFF_SECONDS = [5, 15]  # waits before attempt 2 and 3


def utc_now_iso() -> str:
    return datetime.now(UTC).isoformat()


def normalize_email(value: str | None) -> str:
    return (value or "").strip().lower()


def sender_allowed(sender: str, allowlist: list[str] | None) -> bool:
    if not allowlist:
        return True
    sender_norm = normalize_email(sender)
    allowed = {normalize_email(item) for item in allowlist if str(item).strip()}
    return sender_norm in allowed


def subject_allowed(subject: str, keywords: list[str] | None) -> bool:
    if not keywords:
        return True
    subject_lower = (subject or "").strip().lower()
    for token in keywords:
        key = str(token).strip().lower()
        if key and key in subject_lower:
            return True
    return False


def filename_allowed(filename: str, regex: str | None) -> bool:
    if not regex:
        return True
    try:
        pattern = re.compile(regex, flags=re.IGNORECASE)
    except re.error:
        return False
    return bool(pattern.search(filename or ""))


def labels_allowed(
    labels: list[str] | None,
    label_filter: dict[str, Any] | None,
) -> bool:
    if not label_filter:
        return True
    labels = labels or []
    normalized_labels = {str(item) for item in labels if str(item).strip()}
    required = [str(item) for item in (label_filter.get("label_ids") or []) if str(item).strip()]
    if not required:
        return True
    mode = str(label_filter.get("mode") or "any").strip().lower()
    if mode == "all":
        return all(label in normalized_labels for label in required)
    return any(label in normalized_labels for label in required)


def route_matches_message(
    *,
    route: dict[str, Any],
    sender: str,
    subject: str,
    filename: str,
    labels: list[str] | None = None,
) -> bool:
    return (
        sender_allowed(sender, route.get("sender_allowlist_json"))
        and subject_allowed(subject, route.get("subject_keywords_json"))
        and filename_allowed(filename, route.get("attachment_filename_regex"))
        and labels_allowed(labels, route.get("gmail_label_filter_json"))
    )


def _multipart_body(
    *,
    fields: dict[str, str],
    files: list[tuple[str, str, bytes, str]],
) -> tuple[bytes, str]:
    boundary = f"----ccs-email-ingest-{os.urandom(8).hex()}"
    chunks: list[bytes] = []

    for key, value in fields.items():
        chunks.append(f"--{boundary}\r\n".encode("utf-8"))
        chunks.append(f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("utf-8"))
        chunks.append(value.encode("utf-8"))
        chunks.append(b"\r\n")

    for field_name, filename, content, content_type in files:
        chunks.append(f"--{boundary}\r\n".encode("utf-8"))
        chunks.append(
            f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"\r\n'.encode("utf-8")
        )
        chunks.append(f"Content-Type: {content_type}\r\n\r\n".encode("utf-8"))
        chunks.append(content)
        chunks.append(b"\r\n")

    chunks.append(f"--{boundary}--\r\n".encode("utf-8"))
    body = b"".join(chunks)
    content_type_header = f"multipart/form-data; boundary={boundary}"
    return body, content_type_header


@dataclass
class ApiClient:
    base_url: str
    service_token: str
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS

    def _request(
        self,
        *,
        method: str,
        path: str,
        query: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
        json_body: dict[str, Any] | None = None,
        body: bytes | None = None,
    ) -> tuple[int, dict[str, Any] | None]:
        query = query or {}
        encoded_qs = urllib_parse.urlencode(
            [(key, value) for key, value in query.items() if value is not None],
            doseq=True,
        )
        url = f"{self.base_url.rstrip('/')}{path}"
        if encoded_qs:
            url = f"{url}?{encoded_qs}"

        req_headers = {
            "Authorization": f"Bearer {self.service_token}",
            "Accept": "application/json",
        }
        if headers:
            req_headers.update(headers)

        payload = body
        if json_body is not None:
            payload = json.dumps(json_body).encode("utf-8")
            req_headers["Content-Type"] = "application/json"

        req = urllib_request.Request(
            url=url,
            data=payload,
            method=method.upper(),
            headers=req_headers,
        )
        last_exc: Exception | None = None
        for attempt in range(_RETRY_ATTEMPTS):
            if attempt > 0:
                wait = _RETRY_BACKOFF_SECONDS[attempt - 1]
                time.sleep(wait)
            try:
                with urllib_request.urlopen(req, timeout=self.timeout_seconds) as resp:
                    status = int(resp.status)
                    raw = resp.read().decode("utf-8") if resp.length != 0 else ""
                last_exc = None
                break
            except urllib_error.HTTPError as exc:
                body_text = exc.read().decode("utf-8", errors="ignore")
                raise RuntimeError(f"API {method} {path} failed: HTTP {exc.code} {body_text[:400]}") from exc
            except (TimeoutError, OSError) as exc:  # transient — retry
                last_exc = exc
            except Exception as exc:  # noqa: BLE001
                raise RuntimeError(f"API {method} {path} failed: {exc}") from exc
        if last_exc is not None:
            raise RuntimeError(f"API {method} {path} failed: {last_exc}") from last_exc

        if not raw.strip():
            return status, None
        try:
            return status, json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"API {method} {path} returned invalid JSON") from exc

    def get_paginated(self, path: str, *, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        params = dict(params or {})
        page = 1
        all_items: list[dict[str, Any]] = []
        while True:
            merged = {**params, "page": page, "page_size": 200}
            _status, payload = self._request(method="GET", path=path, query=merged)
            if not isinstance(payload, dict):
                raise RuntimeError(f"Unexpected pagination payload for {path}")
            items = payload.get("items") or []
            if not isinstance(items, list):
                raise RuntimeError(f"Unexpected items payload for {path}")
            typed_items = [item for item in items if isinstance(item, dict)]
            all_items.extend(typed_items)
            total = int(payload.get("total") or len(all_items))
            if len(all_items) >= total or not typed_items:
                break
            page += 1
        return all_items

    def list_mailboxes(self, *, provider: str) -> list[dict[str, Any]]:
        return self.get_paginated(
            "/api/v1/email-ingestion/automation/mailboxes",
            params={"provider": provider, "active": "true"},
        )

    def list_routes(self, *, provider: str) -> list[dict[str, Any]]:
        return self.get_paginated(
            "/api/v1/email-ingestion/automation/routes",
            params={"provider": provider, "active": "true"},
        )

    def oauth_access_token(self, *, provider: str, mailbox_id: int) -> dict[str, Any]:
        _status, payload = self._request(
            method="POST",
            path=f"/api/v1/email-ingestion/oauth/{provider}/access-token",
            json_body={"mailbox_id": mailbox_id},
        )
        if not isinstance(payload, dict):
            raise RuntimeError("OAuth token response must be a JSON object")
        return payload

    def upload_pdf(
        self,
        *,
        route_id: int,
        provider_message_id: str,
        provider_attachment_id: str,
        internet_message_id: str | None,
        provider_received_at: str | None,
        filename: str,
        content: bytes,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        guessed = mimetypes.guess_type(filename)[0] or "application/pdf"
        fields: dict[str, str] = {
            "route_id": str(route_id),
            "provider_message_id": provider_message_id,
            "provider_attachment_id": provider_attachment_id,
        }
        if internet_message_id:
            fields["internet_message_id"] = internet_message_id
        if provider_received_at:
            fields["provider_received_at"] = provider_received_at
        if metadata:
            fields["metadata_json"] = json.dumps(metadata, separators=(",", ":"), ensure_ascii=True)
        body, content_type = _multipart_body(
            fields=fields,
            files=[("file", filename, content, guessed)],
        )
        _status, payload = self._request(
            method="POST",
            path="/api/v1/email-ingestion/upload",
            headers={"Content-Type": content_type},
            body=body,
        )
        if not isinstance(payload, dict):
            raise RuntimeError("Upload response must be a JSON object")
        return payload

    def update_sync_state(
        self,
        *,
        mailbox_id: int,
        sync_state_json: dict[str, Any] | None = None,
        watch_expiration_at: str | None = None,
        last_sync_at: str | None = None,
        last_error_at: str | None = None,
        last_error_message: str | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {}
        if sync_state_json is not None:
            payload["sync_state_json"] = sync_state_json
        if watch_expiration_at is not None:
            payload["watch_expiration_at"] = watch_expiration_at
        if last_sync_at is not None:
            payload["last_sync_at"] = last_sync_at
        if last_error_at is not None:
            payload["last_error_at"] = last_error_at
        if last_error_message is not None:
            payload["last_error_message"] = last_error_message
        _status, response = self._request(
            method="POST",
            path=f"/api/v1/email-ingestion/mailboxes/{mailbox_id}/sync-state",
            json_body=payload,
        )
        if not isinstance(response, dict):
            raise RuntimeError("Sync-state response must be a JSON object")
        return response


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

