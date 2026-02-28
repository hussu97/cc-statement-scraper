from __future__ import annotations

from datetime import UTC, datetime
import json
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from ccs_platform.core.settings import clear_settings_caches
from ccs_platform.main import create_app
from ccs_platform.db import db_session, models
from ccs_platform.api.v1.endpoints import email_ingestion as email_ingestion_endpoint


def _create_app_with_env(monkeypatch: pytest.MonkeyPatch, **kwargs: str) -> object:
    # Use a unique temp file so tests never write to platform.db and each test
    # gets a clean isolated schema (in-memory SQLite doesn't share across connections).
    tmp_db = f"/tmp/ccs_test_{uuid.uuid4().hex}.db"
    monkeypatch.setenv("CCS_PLATFORM_DATABASE_URL", f"sqlite:///{tmp_db}")
    for key, value in kwargs.items():
        monkeypatch.setenv(key, value)
    clear_settings_caches()
    return create_app()


def _new_token_name(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:10]}"


def _create_service_token(client: TestClient, *, scopes: list[str], name_prefix: str = "svc") -> str:
    resp = client.post(
        "/api/v1/email-ingestion/service-tokens",
        json={"name": _new_token_name(name_prefix), "scopes": scopes},
    )
    assert resp.status_code == 200, resp.text
    payload = resp.json()
    return str(payload["token"])


def _pick_enabled_bank_code(client: TestClient) -> str:
    resp = client.get("/api/v1/banks")
    assert resp.status_code == 200
    rows = resp.json()
    assert isinstance(rows, list) and rows
    return str(rows[0]["code"])


def test_mailbox_crud_and_route_upsert(monkeypatch: pytest.MonkeyPatch) -> None:
    test_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_REQUIRE_LOGIN="false",
        CCS_PLATFORM_EMBEDDED_WORKER="false",
        CCS_PLATFORM_EMAIL_INGESTION_ENABLED="true",
    )
    try:
        with TestClient(test_app) as client:
            bank_code = _pick_enabled_bank_code(client)

            mailbox_resp = client.post(
                "/api/v1/email-ingestion/mailboxes",
                json={
                    "provider": "microsoft",
                    "mailbox_email": f"ccs-mailbox-{uuid.uuid4().hex[:6]}@hotmail.com",
                    "display_name": "Primary mailbox",
                    "is_active": True,
                },
            )
            assert mailbox_resp.status_code == 200, mailbox_resp.text
            mailbox = mailbox_resp.json()
            mailbox_id = int(mailbox["id"])

            patch_resp = client.patch(
                f"/api/v1/email-ingestion/mailboxes/{mailbox_id}",
                json={"display_name": "Primary mailbox v2", "is_active": True},
            )
            assert patch_resp.status_code == 200, patch_resp.text
            assert patch_resp.json()["display_name"] == "Primary mailbox v2"

            route_resp = client.put(
                f"/api/v1/email-ingestion/routes/{bank_code}",
                json={
                    "mailbox_id": mailbox_id,
                    "sender_allowlist_json": ["alerts@bank.ae"],
                    "subject_keywords_json": ["statement", "credit card"],
                    "attachment_filename_regex": ".*statement.*\\.pdf",
                    "gmail_label_filter_json": None,
                    "is_active": True,
                },
            )
            assert route_resp.status_code == 200, route_resp.text
            route = route_resp.json()
            assert route["bank_code"] == bank_code
            assert int(route["mailbox_id"]) == mailbox_id

            list_resp = client.get("/api/v1/email-ingestion/routes?page=1&page_size=100")
            assert list_resp.status_code == 200
            items = list_resp.json()["items"]
            assert any(item["bank_code"] == bank_code and int(item["mailbox_id"]) == mailbox_id for item in items)
    finally:
        clear_settings_caches()


def test_service_token_scopes_and_automation_reads(monkeypatch: pytest.MonkeyPatch) -> None:
    test_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_REQUIRE_LOGIN="false",
        CCS_PLATFORM_EMBEDDED_WORKER="false",
        CCS_PLATFORM_EMAIL_INGESTION_ENABLED="true",
    )
    try:
        with TestClient(test_app) as client:
            bank_code = _pick_enabled_bank_code(client)
            mailbox_resp = client.post(
                "/api/v1/email-ingestion/mailboxes",
                json={
                    "provider": "microsoft",
                    "mailbox_email": f"scope-test-{uuid.uuid4().hex[:6]}@hotmail.com",
                    "display_name": "Scope mailbox",
                    "is_active": True,
                },
            )
            assert mailbox_resp.status_code == 200, mailbox_resp.text
            mailbox_id = int(mailbox_resp.json()["id"])
            route_resp = client.put(
                f"/api/v1/email-ingestion/routes/{bank_code}",
                json={"mailbox_id": mailbox_id, "is_active": True},
            )
            assert route_resp.status_code == 200, route_resp.text

            upload_only_token = _create_service_token(
                client,
                scopes=["email_ingestion:upload"],
                name_prefix="upload-only",
            )
            denied = client.get(
                "/api/v1/email-ingestion/automation/routes?provider=microsoft&active=true",
                headers={"Authorization": f"Bearer {upload_only_token}"},
            )
            assert denied.status_code == 403

            read_token = _create_service_token(
                client,
                scopes=["email_ingestion:read"],
                name_prefix="read-only",
            )
            allowed = client.get(
                "/api/v1/email-ingestion/automation/routes?provider=microsoft&active=true",
                headers={"Authorization": f"Bearer {read_token}"},
            )
            assert allowed.status_code == 200, allowed.text
            payload = allowed.json()
            assert payload["total"] >= 1
            assert any(item["bank_code"] == bank_code for item in payload["items"])
    finally:
        clear_settings_caches()


def test_upload_dedupe_hash_and_bank_mismatch(monkeypatch: pytest.MonkeyPatch) -> None:
    test_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_REQUIRE_LOGIN="false",
        CCS_PLATFORM_EMBEDDED_WORKER="false",
        CCS_PLATFORM_EMAIL_INGESTION_ENABLED="true",
    )
    try:
        with TestClient(test_app) as client:
            bank_code = _pick_enabled_bank_code(client)
            mailbox_resp = client.post(
                "/api/v1/email-ingestion/mailboxes",
                json={
                    "provider": "microsoft",
                    "mailbox_email": f"upload-test-{uuid.uuid4().hex[:6]}@hotmail.com",
                    "display_name": "Upload mailbox",
                    "is_active": True,
                },
            )
            assert mailbox_resp.status_code == 200, mailbox_resp.text
            mailbox_id = int(mailbox_resp.json()["id"])
            route_resp = client.put(
                f"/api/v1/email-ingestion/routes/{bank_code}",
                json={"mailbox_id": mailbox_id, "is_active": True},
            )
            assert route_resp.status_code == 200, route_resp.text
            route_id = int(route_resp.json()["id"])

            upload_token = _create_service_token(
                client,
                scopes=["email_ingestion:upload", "email_ingestion:read", "email_ingestion:write"],
                name_prefix="upload",
            )
            unique_suffix = uuid.uuid4().hex[:8]
            msg_1 = f"msg-{unique_suffix}-1"
            msg_2 = f"msg-{unique_suffix}-2"
            msg_3 = f"msg-{unique_suffix}-3"
            att_1 = f"att-{unique_suffix}-1"
            att_2 = f"att-{unique_suffix}-2"
            att_3 = f"att-{unique_suffix}-3"
            pdf_bytes = f"%PDF-1.4\n{unique_suffix}\n%%EOF".encode("utf-8")
            mismatch_pdf_bytes = f"%PDF-1.4\nmismatch-{unique_suffix}\n%%EOF".encode("utf-8")

            first = client.post(
                "/api/v1/email-ingestion/upload",
                headers={"Authorization": f"Bearer {upload_token}"},
                    data={
                        "route_id": str(route_id),
                        "provider_message_id": msg_1,
                        "provider_attachment_id": att_1,
                        "internet_message_id": "<msg-1@example.com>",
                        "provider_received_at": datetime.now(UTC).isoformat(),
                        "metadata_json": json.dumps({"bank_code": bank_code}),
                    },
                files={"file": ("statement.pdf", pdf_bytes, "application/pdf")},
            )
            assert first.status_code == 200, first.text
            assert first.json()["status"] == "uploaded"

            duplicate_by_msg = client.post(
                "/api/v1/email-ingestion/upload",
                headers={"Authorization": f"Bearer {upload_token}"},
                    data={
                        "route_id": str(route_id),
                        "provider_message_id": msg_1,
                        "provider_attachment_id": att_1,
                    },
                    files={"file": ("statement.pdf", pdf_bytes, "application/pdf")},
                )
            assert duplicate_by_msg.status_code == 200, duplicate_by_msg.text
            assert duplicate_by_msg.json()["status"] == "duplicate"

            duplicate_by_hash = client.post(
                "/api/v1/email-ingestion/upload",
                headers={"Authorization": f"Bearer {upload_token}"},
                    data={
                        "route_id": str(route_id),
                        "provider_message_id": msg_2,
                        "provider_attachment_id": att_2,
                    },
                    files={"file": ("statement.pdf", pdf_bytes, "application/pdf")},
                )
            assert duplicate_by_hash.status_code == 200, duplicate_by_hash.text
            assert duplicate_by_hash.json()["status"] == "duplicate"

            mismatch = client.post(
                "/api/v1/email-ingestion/upload",
                headers={"Authorization": f"Bearer {upload_token}"},
                data={
                    "route_id": str(route_id),
                    "provider_message_id": msg_3,
                    "provider_attachment_id": att_3,
                    "metadata_json": json.dumps({"bank_code": "ENBD" if bank_code != "ENBD" else "FAB"}),
                },
                files={"file": ("statement.pdf", mismatch_pdf_bytes, "application/pdf")},
            )
            assert mismatch.status_code == 200, mismatch.text
            assert mismatch.json()["status"] == "ignored"

            events = client.get("/api/v1/email-ingestion/events?page=1&page_size=100")
            assert events.status_code == 200
            statuses = {row["status"] for row in events.json()["items"]}
            assert "uploaded" in statuses
            assert "ignored" in statuses
    finally:
        clear_settings_caches()


def test_oauth_refresh_and_sync_state(monkeypatch: pytest.MonkeyPatch) -> None:
    test_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_REQUIRE_LOGIN="false",
        CCS_PLATFORM_EMBEDDED_WORKER="false",
        CCS_PLATFORM_EMAIL_INGESTION_ENABLED="true",
    )
    try:
        with TestClient(test_app) as client:
            mailbox_resp = client.post(
                "/api/v1/email-ingestion/mailboxes",
                json={
                    "provider": "microsoft",
                    "mailbox_email": f"oauth-test-{uuid.uuid4().hex[:6]}@hotmail.com",
                    "display_name": "OAuth mailbox",
                    "is_active": True,
                },
            )
            assert mailbox_resp.status_code == 200, mailbox_resp.text
            mailbox_id = int(mailbox_resp.json()["id"])

            for key, value, secret in (
                ("EMAIL_MS_CLIENT_ID", "client-id", False),
                ("EMAIL_MS_CLIENT_SECRET", "client-secret", True),
                (f"EMAIL_MS_REFRESH_TOKEN_MAILBOX_{mailbox_id}", "refresh-token", True),
            ):
                resp = client.post(
                    "/api/v1/runtime-settings",
                    json={
                        "key": key,
                        "value": value,
                        "is_secret": secret,
                        "bank_code": None,
                        "description": "email ingestion test setting",
                    },
                )
                assert resp.status_code == 200, resp.text

            monkeypatch.setattr(
                email_ingestion_endpoint,
                "_provider_access_token",
                lambda **_: ("token-from-mock", "Bearer", 3600),
            )

            read_write_token = _create_service_token(
                client,
                scopes=["email_ingestion:read", "email_ingestion:write"],
                name_prefix="oauth",
            )
            oauth_resp = client.post(
                "/api/v1/email-ingestion/oauth/microsoft/access-token",
                headers={"Authorization": f"Bearer {read_write_token}"},
                json={"mailbox_id": mailbox_id},
            )
            assert oauth_resp.status_code == 200, oauth_resp.text
            assert oauth_resp.json()["access_token"] == "token-from-mock"

            sync_resp = client.post(
                f"/api/v1/email-ingestion/mailboxes/{mailbox_id}/sync-state",
                headers={"Authorization": f"Bearer {read_write_token}"},
                json={
                    "sync_state_json": {"delta_link": "https://example.com/delta"},
                    "last_sync_at": datetime.now(UTC).isoformat(),
                    "last_error_message": "",
                },
            )
            assert sync_resp.status_code == 200, sync_resp.text
            payload = sync_resp.json()
            assert isinstance(payload["sync_state_json"], dict)
            assert payload["sync_state_json"]["delta_link"] == "https://example.com/delta"

        with db_session() as db:
            row = db.execute(
                select(models.EmailMailbox).where(models.EmailMailbox.id == mailbox_id)
            ).scalar_one_or_none()
            assert row is not None
            assert isinstance(row.sync_state_json, dict)
            assert row.sync_state_json.get("delta_link") == "https://example.com/delta"
    finally:
        clear_settings_caches()
