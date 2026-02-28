from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from ccs_platform.db import models


class JobRepository:
    def __init__(self, db: Session) -> None:
        self._db = db

    def list_paginated(
        self,
        *,
        profile_id: int,
        page: int = 1,
        page_size: int = 100,
    ) -> tuple[int, list[models.Job]]:
        total = int(
            self._db.execute(
                select(func.count(models.Job.id)).where(models.Job.profile_id == profile_id)
            ).scalar_one()
        )
        rows = (
            self._db.execute(
                select(models.Job)
                .options(selectinload(models.Job.items))
                .where(models.Job.profile_id == profile_id)
                .order_by(models.Job.created_at.desc())
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return total, list(rows)

    def get_by_id(self, job_id: int, *, profile_id: int) -> models.Job | None:
        return self._db.execute(
            select(models.Job)
            .options(selectinload(models.Job.items))
            .where(models.Job.id == job_id, models.Job.profile_id == profile_id)
        ).scalar_one_or_none()

    def get_runtime_settings(
        self,
        *,
        profile_id: int,
        keys: list[str],
    ) -> list[models.RuntimeSetting]:
        return (
            self._db.execute(
                select(models.RuntimeSetting).where(
                    models.RuntimeSetting.profile_id == profile_id,
                    models.RuntimeSetting.key.in_(keys),
                )
            )
            .scalars()
            .all()
        )
