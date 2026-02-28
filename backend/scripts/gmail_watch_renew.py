#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import UTC, datetime
import json
import os
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request

from email_ingestion_common import ApiClient, utc_now_iso


GMAIL_WATCH_ENDPOINT = "https://gmail.googleapis.com/gmail/v1/users/me/watch"


def _gmail_watch(
    *,
    access_token: str,
    topic_name: str,
    label_ids: list[str] | None,
    timeout_seconds: int = 45,
) -> dict[str, Any]:
    payload: dict[str, Any] = {"topicName": topic_name}
    if label_ids:
        payload["labelIds"] = label_ids
        payload["labelFilterAction"] = "include"

    req = urllib_request.Request(
        url=GMAIL_WATCH_ENDPOINT,
        method="POST",
        headers={
            "Authorization": f"Bearer {access_token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
        data=json.dumps(payload).encode("utf-8"),
    )
    try:
        with urllib_request.urlopen(req, timeout=timeout_seconds) as resp:
            raw = resp.read().decode("utf-8")
    except urllib_error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"Gmail watch request failed HTTP {exc.code}: {body[:400]}") from exc
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(f"Gmail watch request failed: {exc}") from exc

    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Gmail watch response is invalid JSON") from exc
    if not isinstance(decoded, dict):
        raise RuntimeError("Gmail watch response must be a JSON object")
    return decoded


def renew_watches(
    *,
    api_base_url: str,
    service_token: str,
    topic_name: str,
    dry_run: bool = False,
) -> dict[str, Any]:
    api = ApiClient(base_url=api_base_url, service_token=service_token)
    mailboxes = api.list_mailboxes(provider="gmail")
    routes = api.list_routes(provider="gmail")
    routes_by_mailbox: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for route in routes:
        try:
            mailbox_id = int(route.get("mailbox_id"))
        except Exception:  # noqa: BLE001
            continue
        routes_by_mailbox[mailbox_id].append(route)

    summary: dict[str, Any] = {
        "provider": "gmail",
        "started_at": utc_now_iso(),
        "mailboxes_total": len(mailboxes),
        "mailboxes_renewed": 0,
        "mailbox_errors": [],
    }

    for mailbox in mailboxes:
        mailbox_id = int(mailbox["id"])
        mailbox_routes = routes_by_mailbox.get(mailbox_id, [])
        if not mailbox_routes:
            continue

        try:
            oauth = api.oauth_access_token(provider="gmail", mailbox_id=mailbox_id)
            access_token = str(oauth.get("access_token") or "").strip()
            if not access_token:
                raise RuntimeError("Missing gmail access token")

            label_ids: list[str] = []
            for route in mailbox_routes:
                label_filter = route.get("gmail_label_filter_json")
                if not isinstance(label_filter, dict):
                    continue
                labels = [str(item) for item in (label_filter.get("label_ids") or []) if str(item).strip()]
                label_ids.extend(labels)
            deduped_labels = sorted(set(label_ids))

            watch_response = (
                {"historyId": "", "expiration": ""}
                if dry_run
                else _gmail_watch(
                    access_token=access_token,
                    topic_name=topic_name,
                    label_ids=deduped_labels,
                )
            )
            history_id = str(watch_response.get("historyId") or "").strip()
            expiration_raw = str(watch_response.get("expiration") or "").strip()
            expiration_iso: str | None = None
            if expiration_raw.isdigit():
                expiration_iso = datetime.fromtimestamp(int(expiration_raw) / 1000.0, tz=UTC).isoformat()

            next_state = mailbox.get("sync_state_json")
            if not isinstance(next_state, dict):
                next_state = {}
            if history_id:
                next_state["gmail_history_id"] = history_id
            next_state["provider"] = "gmail"
            next_state["gmail_watch_topic"] = topic_name
            next_state["updated_at"] = utc_now_iso()

            if not dry_run:
                api.update_sync_state(
                    mailbox_id=mailbox_id,
                    sync_state_json=next_state,
                    watch_expiration_at=expiration_iso,
                    last_sync_at=utc_now_iso(),
                    last_error_at=None,
                    last_error_message="",
                )
            summary["mailboxes_renewed"] += 1
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
    parser = argparse.ArgumentParser(description="Renew Gmail watch subscriptions for configured mailboxes.")
    parser.add_argument("--base-url", default=os.getenv("CCS_API_BASE_URL", "").strip(), help="Base CCS API URL")
    parser.add_argument("--service-token", default=os.getenv("CCS_SERVICE_TOKEN", "").strip(), help="Service API token")
    parser.add_argument("--topic-name", default=os.getenv("GMAIL_PUBSUB_TOPIC", "").strip(), help="Pub/Sub topic")
    parser.add_argument("--dry-run", action="store_true", help="Do not call Gmail watch or persist sync-state")
    args = parser.parse_args()

    if not args.base_url:
        raise SystemExit("Missing --base-url (or CCS_API_BASE_URL).")
    if not args.service_token:
        raise SystemExit("Missing --service-token (or CCS_SERVICE_TOKEN).")
    if not args.topic_name:
        raise SystemExit("Missing --topic-name (or GMAIL_PUBSUB_TOPIC).")

    report = renew_watches(
        api_base_url=args.base_url,
        service_token=args.service_token,
        topic_name=args.topic_name,
        dry_run=bool(args.dry_run),
    )
    print(json.dumps(report, indent=2))
    return 0 if not report.get("mailbox_errors") else 1


if __name__ == "__main__":
    raise SystemExit(main())
