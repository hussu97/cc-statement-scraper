#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
from collections import defaultdict
from datetime import UTC, datetime
import json
import os
from typing import Any
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request

from email_ingestion_common import ApiClient, route_matches_message, utc_now_iso


GRAPH_BASE = "https://graph.microsoft.com/v1.0"


class GraphClient:
    def __init__(self, *, access_token: str, timeout_seconds: int = 45):
        self.access_token = access_token
        self.timeout_seconds = timeout_seconds

    def get_json(self, url: str) -> dict[str, Any]:
        req = urllib_request.Request(
            url=url,
            method="GET",
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
            raise RuntimeError(f"Graph request failed HTTP {exc.code}: {body[:400]}") from exc
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(f"Graph request failed: {exc}") from exc

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError("Graph response was not valid JSON") from exc
        if not isinstance(payload, dict):
            raise RuntimeError("Graph response must be a JSON object")
        return payload

    def _delta_initial_url(self, *, folder: str) -> str:
        query = urllib_parse.urlencode(
            {
                "$select": "id,internetMessageId,receivedDateTime,subject,from,hasAttachments",
                "$top": "50",
            }
        )
        return f"{GRAPH_BASE}/me/mailFolders/{urllib_parse.quote(folder)}/messages/delta?{query}"

    def list_messages_delta(self, *, delta_link: str | None, folder: str = "Inbox") -> tuple[list[dict[str, Any]], str | None]:
        next_url = (delta_link or "").strip() or self._delta_initial_url(folder=folder)
        messages: list[dict[str, Any]] = []
        newest_delta_link: str | None = None

        while next_url:
            payload = self.get_json(next_url)
            values = payload.get("value") or []
            for item in values:
                if not isinstance(item, dict):
                    continue
                if item.get("@removed") is not None:
                    continue
                if not bool(item.get("hasAttachments")):
                    continue
                messages.append(item)

            next_url = str(payload.get("@odata.nextLink") or "").strip() or None
            maybe_delta = str(payload.get("@odata.deltaLink") or "").strip()
            if maybe_delta:
                newest_delta_link = maybe_delta

        return messages, newest_delta_link or delta_link

    def list_pdf_attachments(self, *, message_id: str) -> list[dict[str, Any]]:
        query = urllib_parse.urlencode({"$select": "id,name,contentType,isInline,size"})
        next_url = f"{GRAPH_BASE}/me/messages/{urllib_parse.quote(message_id)}/attachments?{query}"
        attachments: list[dict[str, Any]] = []

        while next_url:
            payload = self.get_json(next_url)
            values = payload.get("value") or []
            for item in values:
                if not isinstance(item, dict):
                    continue
                filename = str(item.get("name") or "")
                content_type = str(item.get("contentType") or "").lower()
                is_inline = bool(item.get("isInline"))
                if is_inline:
                    continue
                if filename.lower().endswith(".pdf") or content_type == "application/pdf":
                    attachments.append(item)
            next_url = str(payload.get("@odata.nextLink") or "").strip() or None
        return attachments

    def get_attachment_bytes(
        self,
        *,
        message_id: str,
        attachment_id: str,
        attachment_stub: dict[str, Any],
    ) -> bytes:
        payload = attachment_stub
        content_bytes = str(payload.get("contentBytes") or "")
        if not content_bytes:
            url = (
                f"{GRAPH_BASE}/me/messages/{urllib_parse.quote(message_id)}/attachments/"
                f"{urllib_parse.quote(attachment_id)}"
            )
            payload = self.get_json(url)
            content_bytes = str(payload.get("contentBytes") or "")
        if not content_bytes:
            return b""
        try:
            return base64.b64decode(content_bytes)
        except Exception:  # noqa: BLE001
            return b""


def _sender_from_message(message: dict[str, Any]) -> str:
    from_obj = message.get("from")
    if not isinstance(from_obj, dict):
        return ""
    email_obj = from_obj.get("emailAddress")
    if not isinstance(email_obj, dict):
        return ""
    return str(email_obj.get("address") or "")


def run_ingestion(
    *,
    base_url: str,
    service_token: str,
    dry_run: bool = False,
) -> dict[str, Any]:
    api = ApiClient(base_url=base_url, service_token=service_token)
    routes = api.list_routes(provider="microsoft")
    mailboxes = api.list_mailboxes(provider="microsoft")

    mailbox_by_id = {int(item["id"]): item for item in mailboxes if isinstance(item, dict) and item.get("id") is not None}
    routes_by_mailbox: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for route in routes:
        raw_mbid = route.get("mailbox_id")
        if raw_mbid is None:
            continue
        try:
            routes_by_mailbox[int(raw_mbid)].append(route)
        except Exception:  # noqa: BLE001
            continue

    summary: dict[str, Any] = {
        "provider": "microsoft",
        "started_at": utc_now_iso(),
        "mailboxes_total": len(mailbox_by_id),
        "routes_total": len(routes),
        "mailboxes_processed": 0,
        "messages_scanned": 0,
        "attachments_seen": 0,
        "uploads_uploaded": 0,
        "uploads_duplicate": 0,
        "uploads_ignored": 0,
        "uploads_failed": 0,
        "mailbox_errors": [],
    }

    # Folders to scan per mailbox. Well-known Graph folder names.
    SCAN_FOLDERS = ["Inbox", "DeletedItems", "Archive"]

    for mailbox_id, mailbox in mailbox_by_id.items():
        mailbox_routes = sorted(routes_by_mailbox.get(mailbox_id, []), key=lambda row: str(row.get("bank_code") or ""))
        if not mailbox_routes:
            continue
        summary["mailboxes_processed"] += 1
        mailbox_sync_state = mailbox.get("sync_state_json")
        if not isinstance(mailbox_sync_state, dict):
            mailbox_sync_state = {}

        try:
            oauth = api.oauth_access_token(provider="microsoft", mailbox_id=mailbox_id)
            access_token = str(oauth.get("access_token") or "").strip()
            if not access_token:
                raise RuntimeError("Missing provider access token")
            graph = GraphClient(access_token=access_token)

            upload_results = {"uploaded": 0, "duplicate": 0, "ignored": 0, "failed": 0}
            next_sync_state = dict(mailbox_sync_state)

            for folder in SCAN_FOLDERS:
                folder_key = f"microsoft_delta_link_{folder.lower()}"
                # Back-compat: seed Inbox from the old single-key delta link.
                if folder == "Inbox":
                    delta_link = str(
                        mailbox_sync_state.get(folder_key)
                        or mailbox_sync_state.get("microsoft_delta_link")
                        or mailbox_sync_state.get("delta_link")
                        or ""
                    ).strip()
                else:
                    delta_link = str(mailbox_sync_state.get(folder_key) or "").strip()

                try:
                    messages, new_delta_link = graph.list_messages_delta(
                        delta_link=delta_link or None,
                        folder=folder,
                    )
                except RuntimeError as exc:
                    if delta_link and "HTTP 410" in str(exc):
                        messages, new_delta_link = graph.list_messages_delta(delta_link=None, folder=folder)
                    elif "HTTP 404" in str(exc):
                        # Folder doesn't exist for this account (e.g. no Archive) — skip silently.
                        continue
                    else:
                        raise

                summary["messages_scanned"] += len(messages)

                for message in messages:
                    message_id = str(message.get("id") or "").strip()
                    if not message_id:
                        continue
                    sender = _sender_from_message(message)
                    subject = str(message.get("subject") or "")
                    internet_message_id = str(message.get("internetMessageId") or "").strip() or None
                    received_at = str(message.get("receivedDateTime") or "").strip() or None

                    attachments = graph.list_pdf_attachments(message_id=message_id)
                    summary["attachments_seen"] += len(attachments)

                    for attachment in attachments:
                        attachment_id = str(attachment.get("id") or "").strip()
                        filename = str(attachment.get("name") or "statement.pdf").strip() or "statement.pdf"
                        if not attachment_id:
                            continue
                        content = graph.get_attachment_bytes(
                            message_id=message_id,
                            attachment_id=attachment_id,
                            attachment_stub=attachment,
                        )
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
                                    labels=None,
                                )
                            ),
                            None,
                        )
                        if not matched_route:
                            continue
                        route_id = int(matched_route["id"])
                        bank_code = str(matched_route.get("bank_code") or "").upper()

                        if dry_run:
                            upload_results["uploaded"] += 1
                            continue

                        upload = api.upload_pdf(
                            route_id=route_id,
                            provider_message_id=message_id,
                            provider_attachment_id=attachment_id,
                            internet_message_id=internet_message_id,
                            provider_received_at=received_at,
                            filename=filename,
                            content=content,
                            metadata={
                                "bank_code": bank_code,
                                "provider": "microsoft",
                                "folder": folder,
                                "sender": sender,
                                "subject": subject,
                            },
                        )
                        status = str(upload.get("status") or "").strip().lower()
                        if status == "uploaded":
                            upload_results["uploaded"] += 1
                        elif status == "duplicate":
                            upload_results["duplicate"] += 1
                        elif status == "ignored":
                            upload_results["ignored"] += 1
                        else:
                            upload_results["failed"] += 1

                if new_delta_link:
                    next_sync_state[folder_key] = new_delta_link

            summary["uploads_uploaded"] += upload_results["uploaded"]
            summary["uploads_duplicate"] += upload_results["duplicate"]
            summary["uploads_ignored"] += upload_results["ignored"]
            summary["uploads_failed"] += upload_results["failed"]

            next_sync_state["provider"] = "microsoft"
            next_sync_state["updated_at"] = utc_now_iso()
            if not dry_run:
                api.update_sync_state(
                    mailbox_id=mailbox_id,
                    sync_state_json=next_sync_state,
                    last_sync_at=utc_now_iso(),
                    last_error_at=None,
                    last_error_message="",
                )
        except Exception as exc:  # noqa: BLE001
            summary["mailbox_errors"].append(
                {
                    "mailbox_id": mailbox_id,
                    "mailbox_email": mailbox.get("mailbox_email"),
                    "error": str(exc),
                }
            )
            if not dry_run:
                api.update_sync_state(
                    mailbox_id=mailbox_id,
                    last_error_at=datetime.now(UTC).isoformat(),
                    last_error_message=str(exc)[:800],
                )

    summary["finished_at"] = utc_now_iso()
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Ingest Microsoft/Hotmail statement PDFs and upload to CCS API.")
    parser.add_argument("--base-url", default=os.getenv("CCS_API_BASE_URL", "").strip(), help="Base CCS API URL")
    parser.add_argument("--service-token", default=os.getenv("CCS_SERVICE_TOKEN", "").strip(), help="Service API token")
    parser.add_argument("--dry-run", action="store_true", help="Scan and match emails without uploading")
    args = parser.parse_args()

    if not args.base_url:
        raise SystemExit("Missing --base-url (or CCS_API_BASE_URL).")
    if not args.service_token:
        raise SystemExit("Missing --service-token (or CCS_SERVICE_TOKEN).")

    report = run_ingestion(
        base_url=args.base_url,
        service_token=args.service_token,
        dry_run=bool(args.dry_run),
    )
    print(json.dumps(report, indent=2))
    return 0 if not report.get("mailbox_errors") else 1


if __name__ == "__main__":
    raise SystemExit(main())
