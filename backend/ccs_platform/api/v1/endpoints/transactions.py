from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import and_, func, or_, select
from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
from ccs_platform.api.v1.schemas import StatementLineOut, TransactionBulkCategoryPatch, TransactionCategoryPatch
from ccs_platform.domain.categorization.engine import ensure_category
from ccs_platform.application.statements.serializers import to_line_out


router = APIRouter(prefix="/transactions", tags=["transactions"])


@router.get("")
def list_transactions(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    page: int = 1,
    page_size: int = 100,
    bank_codes: list[str] | None = Query(default=None),
    categories: list[str] | None = Query(default=None),
    date_from: date | None = None,
    date_to: date | None = None,
    direction: str | None = None,
    merchant_search: str | None = None,
    min_amount_aed: float | None = None,
    max_amount_aed: float | None = None,
    sort_by: str = "transaction_date",
    sort_dir: str = "desc",
):
    page = max(page, 1)
    page_size = min(max(page_size, 1), 1000)

    query = (
        select(models.StatementLine, models.Statement)
        .join(models.Statement)
        .where(models.Statement.profile_id == profile.profile_id)
    )
    count_query = (
        select(func.count(models.StatementLine.id))
        .join(models.Statement)
        .where(models.Statement.profile_id == profile.profile_id)
    )
    sum_query = (
        select(func.coalesce(func.sum(models.StatementLine.amount_aed), 0))
        .join(models.Statement)
        .where(models.Statement.profile_id == profile.profile_id)
    )

    clauses = []

    if bank_codes:
        clauses.append(models.Statement.bank_code.in_([code.upper() for code in bank_codes]))
    if categories:
        clauses.append(models.StatementLine.category.in_(categories))
    if date_from:
        clauses.append(models.StatementLine.transaction_date >= date_from)
    if date_to:
        clauses.append(models.StatementLine.transaction_date <= date_to)
    if direction:
        if direction.lower() not in {"debit", "credit"}:
            raise HTTPException(status_code=400, detail="direction must be debit or credit")
        clauses.append(models.StatementLine.direction == models.Direction(direction.lower()))
    if merchant_search:
        like = f"%{merchant_search.upper()}%"
        clauses.append(
            or_(
                func.upper(models.StatementLine.merchant_raw).like(like),
                func.upper(models.StatementLine.merchant_normalized).like(like),
            )
        )
    if min_amount_aed is not None:
        clauses.append(models.StatementLine.amount_aed >= min_amount_aed)
    if max_amount_aed is not None:
        clauses.append(models.StatementLine.amount_aed <= max_amount_aed)

    if clauses:
        where = and_(*clauses)
        query = query.where(where)
        count_query = count_query.where(where)
        sum_query = sum_query.where(where)

    sort_field_map = {
        "transaction_date": models.StatementLine.transaction_date,
        "posting_date": models.StatementLine.posting_date,
        "amount_aed": models.StatementLine.amount_aed,
        "merchant": models.StatementLine.merchant_normalized,
        "category": models.StatementLine.category,
        "bank": models.Statement.bank_code,
    }
    sort_col = sort_field_map.get(sort_by, models.StatementLine.transaction_date)
    sort_expr = sort_col.desc() if sort_dir.lower() == "desc" else sort_col.asc()

    total = int(db.execute(count_query).scalar_one())
    filtered_amount_aed_sum = float(db.execute(sum_query).scalar_one() or 0)
    rows = db.execute(
        query.order_by(sort_expr, models.StatementLine.id.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).all()

    items = []
    for line, statement in rows:
        line_out = to_line_out(line).model_dump()
        line_out["bank_code"] = statement.bank_code
        line_out["statement_reference"] = statement.statement_reference
        items.append(line_out)

    return {
        "total": total,
        "filtered_amount_aed_sum": filtered_amount_aed_sum,
        "page": page,
        "page_size": page_size,
        "items": items,
    }


@router.patch("/{line_id}", response_model=StatementLineOut)
def patch_transaction_category(
    line_id: int,
    payload: TransactionCategoryPatch,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> StatementLineOut:
    line = db.execute(
        select(models.StatementLine)
        .join(models.Statement)
        .where(
            models.StatementLine.id == line_id,
            models.Statement.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not line:
        raise HTTPException(status_code=404, detail="Transaction line not found")

    ensure_category(db, payload.category)
    line.category = payload.category
    db.commit()
    db.refresh(line)
    return to_line_out(line)


@router.post("/bulk-category")
def bulk_patch_transaction_category(
    payload: TransactionBulkCategoryPatch,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
):
    if not payload.line_ids:
        raise HTTPException(status_code=400, detail="line_ids is required")

    ensure_category(db, payload.category)
    rows = db.execute(
        select(models.StatementLine)
        .join(models.Statement)
        .where(
            models.StatementLine.id.in_(payload.line_ids),
            models.Statement.profile_id == profile.profile_id,
        )
    ).scalars().all()

    for line in rows:
        line.category = payload.category

    db.commit()
    return {
        "updated_count": len(rows),
        "category": payload.category,
    }
