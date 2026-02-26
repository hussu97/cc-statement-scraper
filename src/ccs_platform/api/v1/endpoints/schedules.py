from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
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
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
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
    db.commit()
    db.refresh(row)
    return ScheduleOut.model_validate(row)


@router.patch("/{schedule_id}", response_model=ScheduleOut)
def patch_schedule(
    schedule_id: int,
    payload: ScheduleUpdate,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> ScheduleOut:
    row = db.execute(
        select(models.Schedule).where(
            models.Schedule.id == schedule_id,
            models.Schedule.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Schedule not found")

    updates = payload.model_dump(exclude_unset=True)
    for key, value in updates.items():
        setattr(row, key, value)

    if "rrule" in updates or "timezone" in updates:
        row.next_run_at = compute_next_run(
            row.rrule,
            timezone=row.timezone,
            now_utc=datetime.now(UTC),
        )

    db.commit()
    db.refresh(row)
    return ScheduleOut.model_validate(row)


@router.delete("/{schedule_id}")
def delete_schedule(
    schedule_id: int,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
):
    row = db.execute(
        select(models.Schedule).where(
            models.Schedule.id == schedule_id,
            models.Schedule.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Schedule not found")
    db.delete(row)
    db.commit()
    return {"deleted": True, "schedule_id": schedule_id}
