#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
from datetime import UTC, datetime
import json
import os
from typing import Any
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request

from fastapi import FastAPI, HTTPException, Request

from email_ingestion_common import ApiClient, route_matches_message, utc_now_iso


GMAIL_API_BASE = "https://gmail.googleapis.com/gmail/v1"
app = FastAPI(title="gmail-ingest-relay")


class GmailClient:
    def __init__(self, *, access_token: str, timeout_seconds: int = 45):
        self.access_token = access_token
        self.timeout_seconds = timeout_seconds

    def _request_json(self, *, method: str, url: str) -> dict[str, Any]:
        req = urllib_request.Request(
            url=url,
            method=method.upper(),
            headers={
                "Authorization": f"Bearer {self.access_token}",
                "Accept": "application/json",
            },
        )
        try:
            with urllib_request.urlopen(req, timeout=self.timeout_seconds) as resp:
                raw = resp.read().decode("utf-8")
        except urllib_error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="ignore")
            raise RuntimeError(f"Gmail API error HTTP {exc.code}: {body[:400]}") from exc
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(f"Gmail API request failed: {exc}") from exc

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError("Gmail API response is invalid JSON") from exc
        if not isinstance(payload, dict):
            raise RuntimeError("Gmail API payload must be a JSON object")
        return payload

    def list_history_message_ids(self, *, start_history_id: str) -> tuple[list[str], str | None]:
        query = urllib_parse.urlencode(
            {
                "startHistoryId": start_history_id,
                "historyTypes": "messageAdded",
                "maxResults": "200",
            }
        )
        next_url = f"{GMAIL_API_BASE}/users/me/history?{query}"
        message_ids: list[str] = []
        newest_history_id: str | None = None

        while next_url:
            payload = self._request_json(method="GET", url=next_url)
            newest = str(payload.get("historyId") or "").strip()
            if newest:
                newest_history_id = newest
            histories = payload.get("history") or []
            for item in histories:
                if not isinstance(item, dict):
                    continue
                msg_added = item.get("messagesAdded") or []
                for wrapper in msg_added:
                    if not isinstance(wrapper, dict):
                        continue
                    message = wrapper.get("message")
                    if not isinstance(message, dict):
                        continue
                    message_id = str(message.get("id") or "").strip()
                    if message_id:
                        message_ids.append(message_id)

            token = str(payload.get("nextPageToken") or "").strip()
            if token:
                next_url = f"{GMAIL_API_BASE}/users/me/history?{query}&pageToken={urllib_parse.quote(token)}"
            else:
                next_url = None

        return sorted(set(message_ids)), newest_history_id

    def get_message(self, *, message_id: str) -> dict[str, Any]:
        query = urllib_parse.urlencode({"format": "full"})
        return self._request_json(
            method="GET",
            url=f"{GMAIL_API_BASE}/users/me/messages/{urllib_parse.quote(message_id)}?{query}",
        )

    def get_attachment_bytes(self, *, message_id: str, attachment_id: str) -> bytes:
        payload = self._request_json(
            method="GET",
            url=(
                f"{GMAIL_API_BASE}/users/me/messages/{urllib_parse.quote(message_id)}/attachments/"
                f"{urllib_parse.quote(attachment_id)}"
            ),
        )
        data = str(payload.get("data") or "").strip()
        if not data:
            return b""
        try:
            return base64.urlsafe_b64decode(data.encode("utf-8"))
        except Exception:  # noqa: BLE001
            return b""


def _header_map(message: dict[str, Any]) -> dict[str, str]:
    payload = message.get("payload")
    if not isinstance(payload, dict):
        return {}
    headers = payload.get("headers") or []
    result: dict[str, str] = {}
    for item in headers:
        if not isinstance(item, dict):
            continue
        key = str(item.get("name") or "").strip().lower()
        value = str(item.get("value") or "").strip()
        if key:
            result[key] = value
    return result


def _walk_parts(part: dict[str, Any]) -> list[dict[str, Any]]:
    results = [part]
    for child in part.get("parts") or []:
        if isinstance(child, dict):
            results.extend(_walk_parts(child))
    return results


def _extract_pdf_attachment_stubs(message: dict[str, Any]) -> list[dict[str, Any]]:
    payload = message.get("payload")
    if not isinstance(payload, dict):
        return []
    attachments: list[dict[str, Any]] = []
    for part in _walk_parts(payload):
        filename = str(part.get("filename") or "").strip()
        mime_type = str(part.get("mimeType") or "").strip().lower()
        body = part.get("body")
        if not isinstance(body, dict):
            continue
        attachment_id = str(body.get("attachmentId") or "").strip()
        if not attachment_id:
            continue
        if filename.lower().endswith(".pdf") or mime_type == "application/pdf":
            attachments.append(
                {
                    "attachment_id": attachment_id,
                    "filename": filename or "statement.pdf",
                }
            )
    return attachments


def _sender_from_from_header(value: str) -> str:
    raw = value.strip()
    if "<" in raw and ">" in raw:
        left = raw.rfind("<")
        right = raw.rfind(">")
        if left >= 0 and right > left:
            return raw[left + 1 : right].strip().lower()
    return raw.lower()


def process_gmail_notification(
    *,
    email_address: str,
    history_id: str | None,
    api_base_url: str,
    service_token: str,
    dry_run: bool = False,
) -> dict[str, Any]:
    api = ApiClient(base_url=api_base_url, service_token=service_token)
    mailboxes = api.list_mailboxes(provider="gmail")
    routes = api.list_routes(provider="gmail")

    mailbox = next(
        (
            row
            for row in mailboxes
            if str(row.get("mailbox_email") or "").strip().lower() == email_address.strip().lower()
        ),
        None,
    )
    if mailbox is None:
        return {"status": "ignored", "detail": f"No active gmail mailbox config for {email_address}"}

    mailbox_id = int(mailbox["id"])
    mailbox_routes = [row for row in routes if int(row.get("mailbox_id") or 0) == mailbox_id]
    if not mailbox_routes:
        return {"status": "ignored", "detail": f"No active gmail routes for mailbox_id={mailbox_id}"}

    sync_state = mailbox.get("sync_state_json")
    if not isinstance(sync_state, dict):
        sync_state = {}
    start_history_id = str(sync_state.get("gmail_history_id") or "").strip()
    pushed_history_id = str(history_id or "").strip()

    # First push after watch enable: capture cursor and wait for next push.
    if not start_history_id and pushed_history_id:
        next_state = dict(sync_state)
        next_state["gmail_history_id"] = pushed_history_id
        next_state["provider"] = "gmail"
        next_state["updated_at"] = utc_now_iso()
        if not dry_run:
            api.update_sync_state(
                mailbox_id=mailbox_id,
                sync_state_json=next_state,
                last_sync_at=utc_now_iso(),
                last_error_at=None,
                last_error_message="",
            )
        return {"status": "ok", "detail": "Initialized gmail history cursor", "mailbox_id": mailbox_id}

    if not start_history_id:
        return {"status": "ignored", "detail": "Missing start_history_id and no pushed history_id"}

    oauth = api.oauth_access_token(provider="gmail", mailbox_id=mailbox_id)
    access_token = str(oauth.get("access_token") or "").strip()
    if not access_token:
        raise RuntimeError("Missing gmail access token")
    gmail = GmailClient(access_token=access_token)

    try:
        message_ids, newest_history_id = gmail.list_history_message_ids(start_history_id=start_history_id)
    except RuntimeError as exc:
        if "HTTP 404" in str(exc) and pushed_history_id:
            next_state = dict(sync_state)
            next_state["gmail_history_id"] = pushed_history_id
            next_state["provider"] = "gmail"
            next_state["updated_at"] = utc_now_iso()
            if not dry_run:
                api.update_sync_state(
                    mailbox_id=mailbox_id,
                    sync_state_json=next_state,
                    last_sync_at=utc_now_iso(),
                    last_error_at=None,
                    last_error_message="",
                )
            return {"status": "ok", "detail": "History cursor reset after expiration", "mailbox_id": mailbox_id}
        raise

    uploaded = 0
    duplicate = 0
    ignored = 0
    failed = 0

    for message_id in message_ids:
        message = gmail.get_message(message_id=message_id)
        headers = _header_map(message)
        sender = _sender_from_from_header(headers.get("from", ""))
        subject = headers.get("subject", "")
        internet_message_id = headers.get("message-id") or None
        label_ids = [str(item) for item in (message.get("labelIds") or []) if str(item).strip()]
        internal_date_ms = str(message.get("internalDate") or "").strip()
        provider_received_at: str | None = None
        if internal_date_ms.isdigit():
            provider_received_at = datetime.fromtimestamp(int(internal_date_ms) / 1000.0, tz=UTC).isoformat()

        for attachment in _extract_pdf_attachment_stubs(message):
            attachment_id = str(attachment["attachment_id"])
            filename = str(attachment["filename"])
            content = gmail.get_attachment_bytes(message_id=message_id, attachment_id=attachment_id)
            if not content:
                continue
            matched_route = next(
                (
                    route
                    for route in mailbox_routes
                    if route_matches_message(
                        route=route,
                        sender=sender,
                        subject=subject,
                        filename=filename,
                        labels=label_ids,
                    )
                ),
                None,
            )
            if not matched_route:
                continue
            route_id = int(matched_route["id"])
            bank_code = str(matched_route.get("bank_code") or "").upper()

            if dry_run:
                uploaded += 1
                continue

            response = api.upload_pdf(
                route_id=route_id,
                provider_message_id=message_id,
                provider_attachment_id=attachment_id,
                internet_message_id=internet_message_id,
                provider_received_at=provider_received_at,
                filename=filename,
                content=content,
                metadata={
                    "bank_code": bank_code,
                    "provider": "gmail",
                    "sender": sender,
                    "subject": subject,
                    "label_ids": label_ids,
                },
            )
            status = str(response.get("status") or "").strip().lower()
            if status == "uploaded":
                uploaded += 1
            elif status == "duplicate":
                duplicate += 1
            elif status == "ignored":
                ignored += 1
            else:
                failed += 1

    next_state = dict(sync_state)
    if newest_history_id:
        next_state["gmail_history_id"] = newest_history_id
    elif pushed_history_id:
        next_state["gmail_history_id"] = pushed_history_id
    next_state["provider"] = "gmail"
    next_state["updated_at"] = utc_now_iso()

    if not dry_run:
        api.update_sync_state(
            mailbox_id=mailbox_id,
            sync_state_json=next_state,
            last_sync_at=utc_now_iso(),
            last_error_at=None,
            last_error_message="",
        )

    return {
        "status": "ok",
        "mailbox_id": mailbox_id,
        "messages_scanned": len(message_ids),
        "uploads_uploaded": uploaded,
        "uploads_duplicate": duplicate,
        "uploads_ignored": ignored,
        "uploads_failed": failed,
    }


def _read_env_base_url() -> str:
    return os.getenv("CCS_API_BASE_URL", "").strip()


def _read_env_service_token() -> str:
    return os.getenv("CCS_SERVICE_TOKEN", "").strip()


def _decode_pubsub_payload(envelope: dict[str, Any]) -> tuple[str, str | None]:
    message = envelope.get("message")
    if not isinstance(message, dict):
        raise HTTPException(status_code=400, detail="Missing Pub/Sub message envelope")

    data = str(message.get("data") or "").strip()
    attributes = message.get("attributes")
    if not isinstance(attributes, dict):
        attributes = {}

    payload: dict[str, Any] = {}
    if data:
        try:
            decoded = base64.b64decode(data).decode("utf-8")
            parsed = json.loads(decoded)
            if isinstance(parsed, dict):
                payload = parsed
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(status_code=400, detail=f"Invalid Pub/Sub data payload: {exc}") from exc

    email_address = (
        str(payload.get("emailAddress") or "").strip()
        or str(attributes.get("emailAddress") or "").strip()
    )
    history_id = str(payload.get("historyId") or "").strip() or None
    if not email_address:
        raise HTTPException(status_code=400, detail="emailAddress is missing in Pub/Sub payload")
    return email_address, history_id


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/pubsub/push")
async def pubsub_push(request: Request) -> dict[str, Any]:
    api_base_url = _read_env_base_url()
    service_token = _read_env_service_token()
    if not api_base_url or not service_token:
        raise HTTPException(status_code=500, detail="CCS_API_BASE_URL and CCS_SERVICE_TOKEN are required")

    try:
        envelope = await request.json()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail="Invalid JSON body") from exc
    if not isinstance(envelope, dict):
        raise HTTPException(status_code=400, detail="Invalid Pub/Sub envelope")

    email_address, history_id = _decode_pubsub_payload(envelope)
    try:
        result = process_gmail_notification(
            email_address=email_address,
            history_id=history_id,
            api_base_url=api_base_url,
            service_token=service_token,
            dry_run=False,
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"received_at": utc_now_iso(), **result}


def main() -> int:
    parser = argparse.ArgumentParser(description="Process a single Gmail notification payload via CCS API.")
    parser.add_argument("--email", required=True, help="Mailbox email address from Gmail watch payload")
    parser.add_argument("--history-id", default="", help="History id from Gmail watch payload")
    parser.add_argument("--base-url", default=_read_env_base_url(), help="Base CCS API URL")
    parser.add_argument("--service-token", default=_read_env_service_token(), help="Service API token")
    parser.add_argument("--dry-run", action="store_true", help="Skip upload + sync-state writes")
    args = parser.parse_args()

    if not args.base_url:
        raise SystemExit("Missing --base-url (or CCS_API_BASE_URL).")
    if not args.service_token:
        raise SystemExit("Missing --service-token (or CCS_SERVICE_TOKEN).")

    result = process_gmail_notification(
        email_address=args.email,
        history_id=args.history_id or None,
        api_base_url=args.base_url,
        service_token=args.service_token,
        dry_run=bool(args.dry_run),
    )
    print(json.dumps(result, indent=2))
    return 0 if str(result.get("status")) in {"ok", "ignored"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
