from __future__ import annotations

from typing import Any

from fastapi import Request
from sqlalchemy.orm import Session

from ccs_platform.db import models


def actor_metadata(request: Request) -> dict[str, str | None]:
    return {
        "role": str(getattr(request.state, "actor_role", "") or "").strip() or None,
        "subject": str(getattr(request.state, "actor_subject", "") or "").strip() or None,
        "request_id": str(getattr(request.state, "request_id", "") or "").strip() or None,
    }


def append_audit_event(
    db: Session,
    *,
    profile_id: int,
    event_type: str,
    entity_type: str,
    entity_id: str,
    payload_json: dict[str, Any] | None,
    request: Request | None = None,
) -> None:
    payload: dict[str, Any] = dict(payload_json or {})
    if request is not None:
        payload["actor"] = actor_metadata(request)

    db.add(
        models.AuditEvent(
            profile_id=profile_id,
            event_type=event_type,
            entity_type=entity_type,
            entity_id=entity_id,
            payload_json=payload or None,
        )
    )
