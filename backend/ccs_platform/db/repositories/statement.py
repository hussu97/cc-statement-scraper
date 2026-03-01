from __future__ import annotations

from collections import defaultdict
from datetime import date

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ccs_platform.db import models


class StatementRepository:
    def __init__(self, db: Session) -> None:
        self._db = db

    def list_paginated(
        self,
        *,
        profile_id: int,
        page: int = 1,
        page_size: int = 100,
        bank_codes: list[str] | None = None,
        statement_reference: str | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
    ) -> tuple[int, list[models.Statement]]:
        query = select(models.Statement).where(models.Statement.profile_id == profile_id)
        count_query = select(func.count(models.Statement.id)).where(
            models.Statement.profile_id == profile_id
        )

        if bank_codes:
            query = query.where(models.Statement.bank_code.in_(bank_codes))
            count_query = count_query.where(models.Statement.bank_code.in_(bank_codes))

        if statement_reference:
            like = f"%{statement_reference.upper()}%"
            query = query.where(func.upper(models.Statement.statement_reference).like(like))
            count_query = count_query.where(
                func.upper(models.Statement.statement_reference).like(like)
            )

        if date_from:
            query = query.where(models.Statement.statement_date >= date_from)
            count_query = count_query.where(models.Statement.statement_date >= date_from)

        if date_to:
            query = query.where(models.Statement.statement_date <= date_to)
            count_query = count_query.where(models.Statement.statement_date <= date_to)

        total = int(self._db.execute(count_query).scalar_one())
        rows = (
            self._db.execute(
                query.order_by(models.Statement.statement_date.desc())
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return total, list(rows)

    def get_by_id(self, statement_id: int, *, profile_id: int) -> models.Statement | None:
        return self._db.execute(
            select(models.Statement).where(
                models.Statement.id == statement_id,
                models.Statement.profile_id == profile_id,
            )
        ).scalar_one_or_none()

    def count_lines(self, statement_id: int) -> int:
        return int(
            self._db.execute(
                select(func.count(models.StatementLine.id)).where(
                    models.StatementLine.statement_id == statement_id
                )
            ).scalar_one()
        )

    def line_counts_for_ids(self, statement_ids: list[int]) -> dict[int, int]:
        if not statement_ids:
            return defaultdict(int)
        counts = self._db.execute(
            select(models.StatementLine.statement_id, func.count(models.StatementLine.id))
            .where(models.StatementLine.statement_id.in_(statement_ids))
            .group_by(models.StatementLine.statement_id)
        ).all()
        return defaultdict(int, {sid: int(count) for sid, count in counts})

    def amount_totals_for_ids(
        self, statement_ids: list[int]
    ) -> dict[int, dict[str, float]]:
        """Return {statement_id: {"debit": float, "credit": float}} for the given ids."""
        if not statement_ids:
            return defaultdict(lambda: {"debit": 0.0, "credit": 0.0})
        rows = self._db.execute(
            select(
                models.StatementLine.statement_id,
                models.StatementLine.direction,
                func.coalesce(func.sum(models.StatementLine.amount_aed), 0),
            )
            .where(models.StatementLine.statement_id.in_(statement_ids))
            .group_by(models.StatementLine.statement_id, models.StatementLine.direction)
        ).all()
        result: dict[int, dict[str, float]] = defaultdict(lambda: {"debit": 0.0, "credit": 0.0})
        for sid, direction, total in rows:
            result[sid][direction.value] = float(total)
        return result

    def get_lines_for_statement(self, statement_id: int) -> list[models.StatementLine]:
        return (
            self._db.execute(
                select(models.StatementLine).where(
                    models.StatementLine.statement_id == statement_id
                )
            )
            .scalars()
            .all()
        )

    def list_lines_paginated(
        self,
        statement_id: int,
        *,
        page: int = 1,
        page_size: int = 100,
        search: str | None = None,
    ) -> tuple[int, list[models.StatementLine]]:
        query = select(models.StatementLine).where(
            models.StatementLine.statement_id == statement_id
        )
        count_query = select(func.count(models.StatementLine.id)).where(
            models.StatementLine.statement_id == statement_id
        )

        if search:
            like = f"%{search.upper()}%"
            query = query.where(
                func.upper(models.StatementLine.merchant_normalized).like(like)
            )
            count_query = count_query.where(
                func.upper(models.StatementLine.merchant_normalized).like(like)
            )

        total = int(self._db.execute(count_query).scalar_one())
        rows = (
            self._db.execute(
                query.order_by(models.StatementLine.line_no.asc())
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return total, list(rows)

    def get_pdf_file(self, pdf_file_id: int, *, profile_id: int) -> models.PdfFile | None:
        return self._db.execute(
            select(models.PdfFile).where(
                models.PdfFile.id == pdf_file_id,
                models.PdfFile.profile_id == profile_id,
            )
        ).scalar_one_or_none()

    def date_conflict_exists(
        self,
        *,
        profile_id: int,
        exclude_id: int,
        bank_code: str,
        statement_reference: str,
        new_date: date,
    ) -> bool:
        result = self._db.execute(
            select(models.Statement.id).where(
                models.Statement.profile_id == profile_id,
                models.Statement.id != exclude_id,
                models.Statement.bank_code == bank_code,
                models.Statement.statement_reference == statement_reference,
                models.Statement.statement_date == new_date,
            )
        ).scalar_one_or_none()
        return result is not None
