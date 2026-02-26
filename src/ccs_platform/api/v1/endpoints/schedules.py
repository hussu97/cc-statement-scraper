from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ccs_platform.api.audit import append_audit_event
from ccs_platform.db import models
from ccs_platform.api.deps import (
    ActorContext,
    ProfileContext,
    get_db,
    get_profile_context,
    require_operator_role,
)
from ccs_platform.api.v1.schemas import PaginatedSchedules, ScheduleCreate, ScheduleOut, ScheduleUpdate
from ccs_platform.application.jobs.scheduler import compute_next_run


router = APIRouter(prefix="/schedules", tags=["schedules"])


@router.get("", response_model=PaginatedSchedules)
def list_schedules(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    page: int = 1,
    page_size: int = 100,
) -> PaginatedSchedules:
    page = max(page, 1)
    page_size = min(max(page_size, 1), 1000)

    count_query = select(func.count(models.Schedule.id)).where(models.Schedule.profile_id == profile.profile_id)
    total = int(db.execute(count_query).scalar_one())

    rows = db.execute(
        select(models.Schedule)
        .where(models.Schedule.profile_id == profile.profile_id)
        .order_by(models.Schedule.id.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).scalars().all()
    return PaginatedSchedules(
        total=total,
        page=page,
        page_size=page_size,
        items=[ScheduleOut.model_validate(row) for row in rows],
    )


@router.post("", response_model=ScheduleOut)
def create_schedule(
    payload: ScheduleCreate,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
) -> ScheduleOut:
    next_run = compute_next_run(
        payload.rrule,
        timezone=payload.timezone,
        now_utc=datetime.now(UTC),
    )

    row = models.Schedule(
        profile_id=profile.profile_id,
        name=payload.name,
        job_type=payload.job_type,
        payload_json=payload.payload_json,
        rrule=payload.rrule,
        timezone=payload.timezone,
        status=payload.status,
        next_run_at=next_run,
    )
    db.add(row)
    append_audit_event(
        db,
        profile_id=profile.profile_id,
        event_type="schedule_created",
        entity_type="schedule",
        entity_id=row.name,
        payload_json={
            "job_type": row.job_type.value,
            "rrule": row.rrule,
            "timezone": row.timezone,
            "status": row.status.value,
            "next_run_at": row.next_run_at.isoformat() if row.next_run_at is not None else None,
        },
        request=request,
    )
    db.commit()
    db.refresh(row)
    return ScheduleOut.model_validate(row)


@router.patch("/{schedule_id}", response_model=ScheduleOut)
def patch_schedule(
    schedule_id: int,
    payload: ScheduleUpdate,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
) -> ScheduleOut:
    row = db.execute(
        select(models.Schedule).where(
            models.Schedule.id == schedule_id,
            models.Schedule.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Schedule not found")

    before = {
        "name": row.name,
        "status": row.status.value,
        "rrule": row.rrule,
        "timezone": row.timezone,
        "next_run_at": row.next_run_at.isoformat() if row.next_run_at is not None else None,
    }
    updates = payload.model_dump(exclude_unset=True)
    for key, value in updates.items():
        setattr(row, key, value)

    if "rrule" in updates or "timezone" in updates:
        row.next_run_at = compute_next_run(
            row.rrule,
            timezone=row.timezone,
            now_utc=datetime.now(UTC),
        )

    append_audit_event(
        db,
        profile_id=profile.profile_id,
        event_type="schedule_updated",
        entity_type="schedule",
        entity_id=str(row.id),
        payload_json={
            "before": before,
            "after": {
                "name": row.name,
                "status": row.status.value,
                "rrule": row.rrule,
                "timezone": row.timezone,
                "next_run_at": row.next_run_at.isoformat() if row.next_run_at is not None else None,
            },
        },
        request=request,
    )
    db.commit()
    db.refresh(row)
    return ScheduleOut.model_validate(row)


@router.delete("/{schedule_id}")
def delete_schedule(
    schedule_id: int,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
):
    row = db.execute(
        select(models.Schedule).where(
            models.Schedule.id == schedule_id,
            models.Schedule.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Schedule not found")
    append_audit_event(
        db,
        profile_id=profile.profile_id,
        event_type="schedule_deleted",
        entity_type="schedule",
        entity_id=str(row.id),
        payload_json={
            "name": row.name,
            "job_type": row.job_type.value,
            "rrule": row.rrule,
            "status": row.status.value,
        },
        request=request,
    )
    db.delete(row)
    db.commit()
    return {"deleted": True, "schedule_id": schedule_id}
