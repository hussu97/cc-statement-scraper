from __future__ import annotations

from ccs_platform.api.v1.endpoints.email_ingestion import _email_ingestion_job_idempotency_key


def test_email_ingestion_idempotency_key_hashes_full_provider_identity() -> None:
    common_prefix = "AQMkADAwATY0MDABLWU3NwAwLWY0YzQtMDACLTAwCgBGAAAD" + ("x" * 120)
    first_message_id = f"{common_prefix}-message-a"
    second_message_id = f"{common_prefix}-message-b"
    attachment_id = f"{common_prefix}-attachment"

    first_key = _email_ingestion_job_idempotency_key(
        route_id=3,
        provider_message_id=first_message_id,
        provider_attachment_id=attachment_id,
    )
    second_key = _email_ingestion_job_idempotency_key(
        route_id=3,
        provider_message_id=second_message_id,
        provider_attachment_id=attachment_id,
    )
    repeat_key = _email_ingestion_job_idempotency_key(
        route_id=3,
        provider_message_id=first_message_id,
        provider_attachment_id=attachment_id,
    )

    assert first_key != second_key
    assert first_key == repeat_key
    assert len(first_key) <= 128
    assert first_key.startswith("email-ingest:3:")
