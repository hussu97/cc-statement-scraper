from __future__ import annotations

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from ccs_platform.db import models


class CategoryRepository:
    def __init__(self, db: Session) -> None:
        self._db = db

    def list_all_categories(self) -> list[models.Category]:
        return (
            self._db.execute(
                select(models.Category).order_by(models.Category.name.asc())
            )
            .scalars()
            .all()
        )

    def list_rules_paginated(
        self,
        *,
        page: int = 1,
        page_size: int = 100,
        search: str | None = None,
    ) -> tuple[int, list[models.CategoryRule]]:
        query = select(models.CategoryRule)
        count_query = select(func.count(models.CategoryRule.id))

        if search:
            token = f"%{search.strip().upper()}%"
            predicate = or_(
                func.upper(models.CategoryRule.name).like(token),
                func.upper(models.CategoryRule.category_name).like(token),
                func.upper(models.CategoryRule.pattern).like(token),
            )
            query = query.where(predicate)
            count_query = count_query.where(predicate)

        total = int(self._db.execute(count_query).scalar_one())
        rows = (
            self._db.execute(
                query.order_by(
                    func.length(models.CategoryRule.pattern).desc(),
                    models.CategoryRule.id.asc(),
                )
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return total, list(rows)
