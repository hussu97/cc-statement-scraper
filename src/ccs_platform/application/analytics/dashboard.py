from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from typing import Any

from sqlalchemy import and_, case, func, or_, select
from sqlalchemy.orm import Session

from ccs_platform.db import models


@dataclass
class DashboardFilters:
    profile_id: int
    bank_codes: list[str] | None = None
    categories: list[str] | None = None
    date_from: date | None = None
    date_to: date | None = None
    merchant_search: str | None = None
    direction: str | None = None


def _month_floor(value: date) -> date:
    return date(value.year, value.month, 1)


def month_buckets(date_from: date, date_to: date) -> list[str]:
    start = _month_floor(date_from)
    end = _month_floor(date_to)

    buckets: list[str] = []
    current = start
    while current <= end:
        buckets.append(current.strftime("%Y-%m"))
        if current.month == 12:
            current = date(current.year + 1, 1, 1)
        else:
            current = date(current.year, current.month + 1, 1)
    return buckets


def month_bucket_expr(db: Session):
    dialect = (db.bind.dialect.name if db.bind is not None else "sqlite").lower()
    if dialect == "sqlite":
        return func.strftime("%Y-%m", models.StatementLine.transaction_date)
    return func.to_char(models.StatementLine.transaction_date, "YYYY-MM")


def _copy_with_bounds(filters: DashboardFilters, *, date_from: date, date_to: date) -> DashboardFilters:
    return DashboardFilters(
        profile_id=filters.profile_id,
        bank_codes=filters.bank_codes,
        categories=filters.categories,
        date_from=date_from,
        date_to=date_to,
        merchant_search=filters.merchant_search,
        direction=filters.direction,
    )


def _copy_with_direction(filters: DashboardFilters, *, direction: str | None) -> DashboardFilters:
    return DashboardFilters(
        profile_id=filters.profile_id,
        bank_codes=filters.bank_codes,
        categories=filters.categories,
        date_from=filters.date_from,
        date_to=filters.date_to,
        merchant_search=filters.merchant_search,
        direction=direction,
    )


def _apply_filters(query, *, filters: DashboardFilters, include_dates: bool = True):
    clauses = [models.Statement.profile_id == filters.profile_id]

    if filters.bank_codes:
        bank_tokens = sorted({token.upper().strip() for token in filters.bank_codes if token and token.strip()})
        if bank_tokens:
            clauses.append(models.Statement.bank_code.in_(bank_tokens))

    if filters.categories:
        category_tokens = sorted({token.strip() for token in filters.categories if token and token.strip()})
        if category_tokens:
            clauses.append(models.StatementLine.category.in_(category_tokens))

    if include_dates and filters.date_from:
        clauses.append(models.StatementLine.transaction_date >= filters.date_from)
    if include_dates and filters.date_to:
        clauses.append(models.StatementLine.transaction_date <= filters.date_to)

    if filters.merchant_search:
        like = f"%{filters.merchant_search.upper()}%"
        clauses.append(
            or_(
                func.upper(models.StatementLine.merchant_raw).like(like),
                func.upper(models.StatementLine.merchant_normalized).like(like),
            )
        )

    direction = (filters.direction or "").strip().lower()
    if direction in {"debit", "credit"}:
        clauses.append(models.StatementLine.direction == models.Direction(direction))

    if clauses:
        query = query.where(and_(*clauses))

    return query


def _debit_case():
    return case(
        (models.StatementLine.direction == models.Direction.DEBIT, func.coalesce(models.StatementLine.amount_aed, 0.0)),
        else_=0.0,
    )


def _credit_case():
    return case(
        (
            models.StatementLine.direction == models.Direction.CREDIT,
            func.abs(func.coalesce(models.StatementLine.amount_aed, 0.0)),
        ),
        else_=0.0,
    )


def resolve_date_bounds(db: Session, *, filters: DashboardFilters) -> tuple[date | None, date | None]:
    query = (
        select(
            func.min(models.StatementLine.transaction_date),
            func.max(models.StatementLine.transaction_date),
        )
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    query = _apply_filters(query, filters=filters, include_dates=True)
    min_date, max_date = db.execute(query).one()
    return min_date, max_date


def _effective_bounds(db: Session, *, filters: DashboardFilters) -> tuple[date | None, date | None]:
    if filters.date_from and filters.date_to:
        return filters.date_from, filters.date_to

    min_date, max_date = resolve_date_bounds(db, filters=filters)
    if min_date is None or max_date is None:
        if filters.date_from and filters.date_to is None:
            return filters.date_from, filters.date_from
        if filters.date_to and filters.date_from is None:
            return filters.date_to, filters.date_to
        return None, None

    return filters.date_from or min_date, filters.date_to or max_date


def fetch_overview(db: Session, *, filters: DashboardFilters) -> dict[str, Any]:
    summary_query = (
        select(
            func.sum(_debit_case()).label("total_spend"),
            func.sum(_credit_case()).label("total_credit"),
            func.sum(case((models.StatementLine.category == "Uncategorized", 1), else_=0)).label("uncategorized_count"),
            func.count(models.StatementLine.id).label("line_count"),
            func.count(func.distinct(models.Statement.id)).label("statement_count"),
        )
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    summary_query = _apply_filters(summary_query, filters=filters, include_dates=True)
    summary = db.execute(summary_query).one()

    total_spend = round(float(summary.total_spend or 0.0), 2)
    total_credit = round(float(summary.total_credit or 0.0), 2)
    uncategorized_count = int(summary.uncategorized_count or 0)
    line_count = int(summary.line_count or 0)
    statement_count = int(summary.statement_count or 0)

    mom_delta = None
    start, end = _effective_bounds(db, filters=filters)
    if start and end:
        bucket_expr = month_bucket_expr(db)
        monthly_query = (
            select(
                bucket_expr.label("bucket"),
                func.sum(_debit_case()).label("debit_total"),
            )
            .select_from(models.StatementLine)
            .join(models.Statement)
        )
        monthly_query = _apply_filters(monthly_query, filters=_copy_with_bounds(filters, date_from=start, date_to=end))
        monthly_query = monthly_query.group_by(bucket_expr).order_by(bucket_expr)
        monthly_totals = {
            row.bucket: float(row.debit_total or 0.0)
            for row in db.execute(monthly_query).all()
        }

        buckets = month_buckets(start, end)
        if len(buckets) >= 2:
            prev = monthly_totals.get(buckets[-2], 0.0)
            curr = monthly_totals.get(buckets[-1], 0.0)
            if prev != 0:
                mom_delta = ((curr - prev) / abs(prev)) * 100.0

    return {
        "total_spend_aed": total_spend,
        "total_credits_aed": total_credit,
        "uncategorized_count": uncategorized_count,
        "uncategorized_ratio": round((uncategorized_count / line_count) if line_count else 0.0, 4),
        "statement_count": statement_count,
        "mom_delta_pct": round(mom_delta, 2) if mom_delta is not None else None,
    }


def fetch_trend_series(db: Session, *, filters: DashboardFilters) -> list[dict[str, float | str]]:
    start, end = _effective_bounds(db, filters=filters)
    if start is None or end is None:
        return []

    effective_filters = _copy_with_bounds(filters, date_from=start, date_to=end)
    bucket_expr = month_bucket_expr(db)

    query = (
        select(
            bucket_expr.label("bucket"),
            func.sum(_debit_case()).label("debit"),
            func.sum(_credit_case()).label("credit"),
        )
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    query = _apply_filters(query, filters=effective_filters)
    query = query.group_by(bucket_expr).order_by(bucket_expr)

    indexed = {
        row.bucket: {
            "debit_aed": round(float(row.debit or 0.0), 2),
            "credit_aed": round(float(row.credit or 0.0), 2),
        }
        for row in db.execute(query).all()
    }

    points: list[dict[str, float | str]] = []
    for bucket in month_buckets(start, end):
        debit = float(indexed.get(bucket, {}).get("debit_aed", 0.0))
        credit = float(indexed.get(bucket, {}).get("credit_aed", 0.0))
        points.append(
            {
                "bucket": bucket,
                "debit_aed": round(debit, 2),
                "credit_aed": round(credit, 2),
                "net_aed": round(debit - credit, 2),
            }
        )
    return points


def fetch_bank_trend_series(db: Session, *, filters: DashboardFilters) -> dict[str, Any]:
    start, end = _effective_bounds(db, filters=filters)
    if start is None or end is None:
        return {"buckets": [], "series": []}

    buckets = month_buckets(start, end)
    effective_filters = _copy_with_bounds(filters, date_from=start, date_to=end)
    bucket_expr = month_bucket_expr(db)

    query = (
        select(
            bucket_expr.label("bucket"),
            models.Statement.bank_code.label("bank_code"),
            func.sum(_debit_case()).label("value_aed"),
        )
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    query = _apply_filters(query, filters=effective_filters)
    query = query.group_by(bucket_expr, models.Statement.bank_code).order_by(bucket_expr, models.Statement.bank_code)

    rows = db.execute(query).all()
    if filters.bank_codes:
        bank_keys = sorted({token.upper().strip() for token in filters.bank_codes if token and token.strip()})
    else:
        bank_keys = sorted({row.bank_code for row in rows if row.bank_code})

    if not bank_keys:
        return {"buckets": buckets, "series": []}

    indexed: dict[str, dict[str, float]] = {bank_key: {} for bank_key in bank_keys}
    for row in rows:
        if row.bank_code not in indexed:
            indexed[row.bank_code] = {}
        indexed[row.bank_code][row.bucket] = round(float(row.value_aed or 0.0), 2)

    return {
        "buckets": buckets,
        "series": [
            {
                "key": bank_key,
                "points": [
                    {
                        "bucket": bucket,
                        "value_aed": indexed[bank_key].get(bucket, 0.0),
                    }
                    for bucket in buckets
                ],
            }
            for bank_key in sorted(indexed)
        ],
    }


def fetch_category_trend_series(db: Session, *, filters: DashboardFilters, top_n: int = 12) -> dict[str, Any]:
    top_n = max(1, min(top_n, 20))

    start, end = _effective_bounds(db, filters=filters)
    if start is None or end is None:
        return {"buckets": [], "series": []}

    buckets = month_buckets(start, end)
    effective_filters = _copy_with_bounds(filters, date_from=start, date_to=end)

    bucket_expr = month_bucket_expr(db)
    bucket = bucket_expr.label("bucket")
    category = func.coalesce(models.StatementLine.category, "Uncategorized").label("category")

    totals_query = (
        select(
            category,
            func.sum(_debit_case()).label("total_aed"),
        )
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    totals_query = _apply_filters(totals_query, filters=effective_filters)
    totals_query = totals_query.group_by(category).order_by(func.sum(_debit_case()).desc(), category.asc())

    totals_rows = db.execute(totals_query).all()
    top_categories = [row.category for row in totals_rows[:top_n] if row.category]

    if not top_categories:
        return {"buckets": buckets, "series": []}

    by_category_query = (
        select(
            bucket,
            category,
            func.sum(_debit_case()).label("value_aed"),
        )
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    by_category_query = _apply_filters(by_category_query, filters=effective_filters)
    by_category_query = by_category_query.group_by(bucket_expr, category).order_by(bucket_expr, category)

    by_bucket_total_query = (
        select(
            bucket,
            func.sum(_debit_case()).label("value_aed"),
        )
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    by_bucket_total_query = _apply_filters(by_bucket_total_query, filters=effective_filters)
    by_bucket_total_query = by_bucket_total_query.group_by(bucket_expr).order_by(bucket_expr)

    totals_by_bucket = {row.bucket: round(float(row.value_aed or 0.0), 2) for row in db.execute(by_bucket_total_query).all()}

    indexed: dict[str, dict[str, float]] = {category_key: {} for category_key in top_categories}
    for row in db.execute(by_category_query).all():
        category_key = row.category
        if category_key in indexed:
            indexed[category_key][row.bucket] = round(float(row.value_aed or 0.0), 2)

    series = [
        {
            "key": category_key,
            "points": [
                {
                    "bucket": bucket_key,
                    "value_aed": indexed[category_key].get(bucket_key, 0.0),
                }
                for bucket_key in buckets
            ],
        }
        for category_key in top_categories
    ]

    has_other = len(totals_rows) > len(top_categories)
    if has_other:
        other_points = []
        for bucket_key in buckets:
            top_sum = sum(indexed[category_key].get(bucket_key, 0.0) for category_key in top_categories)
            other_value = round(max(totals_by_bucket.get(bucket_key, 0.0) - top_sum, 0.0), 2)
            other_points.append({"bucket": bucket_key, "value_aed": other_value})
        series.append({"key": "Other", "points": other_points})

    return {
        "buckets": buckets,
        "series": series,
    }


def fetch_category_breakdown(db: Session, *, filters: DashboardFilters) -> list[dict[str, float | str]]:
    category = func.coalesce(models.StatementLine.category, "Uncategorized").label("key")
    query = (
        select(category, func.sum(_debit_case()).label("value"))
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    query = _apply_filters(query, filters=filters)
    query = query.group_by(category).order_by(func.sum(_debit_case()).desc(), category.asc())

    rows = db.execute(query).all()
    return [
        {"key": str(row.key), "value": round(float(row.value or 0.0), 2)}
        for row in rows
        if round(float(row.value or 0.0), 2) != 0.0
    ]


def fetch_bank_breakdown(db: Session, *, filters: DashboardFilters) -> list[dict[str, float | str]]:
    query = (
        select(models.Statement.bank_code.label("key"), func.sum(_debit_case()).label("value"))
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    query = _apply_filters(query, filters=filters)
    query = query.group_by(models.Statement.bank_code).order_by(func.sum(_debit_case()).desc(), models.Statement.bank_code.asc())

    rows = db.execute(query).all()
    return [
        {"key": str(row.key), "value": round(float(row.value or 0.0), 2)}
        for row in rows
        if round(float(row.value or 0.0), 2) != 0.0
    ]


def fetch_top_merchants(
    db: Session,
    *,
    filters: DashboardFilters,
    limit: int = 20,
    direction: str = "debit",
) -> list[dict[str, float | str]]:
    cap = max(1, min(limit, 100))
    normalized_direction = (direction or "debit").strip().lower()
    if normalized_direction not in {"debit", "credit"}:
        normalized_direction = "debit"

    amount_expr = _credit_case() if normalized_direction == "credit" else _debit_case()
    scoped_filters = _copy_with_direction(filters, direction=normalized_direction)
    merchant = func.coalesce(models.StatementLine.merchant_normalized, models.StatementLine.merchant_raw).label("key")
    query = (
        select(merchant, func.sum(amount_expr).label("value"))
        .select_from(models.StatementLine)
        .join(models.Statement)
    )
    query = _apply_filters(query, filters=scoped_filters)
    query = query.group_by(merchant).order_by(func.sum(amount_expr).desc(), merchant.asc()).limit(cap)

    rows = db.execute(query).all()
    return [
        {"key": str(row.key), "value": round(float(row.value or 0.0), 2)}
        for row in rows
        if round(float(row.value or 0.0), 2) != 0.0
    ]


def fetch_filter_meta(db: Session, *, profile_id: int) -> dict[str, Any]:
    banks = db.execute(
        select(models.ProfileBank.bank_code)
        .where(models.ProfileBank.profile_id == profile_id)
        .order_by(models.ProfileBank.bank_code.asc())
    ).scalars().all()

    category_catalog = db.execute(select(models.Category.name)).scalars().all()
    line_categories = db.execute(
        select(models.StatementLine.category)
        .join(models.Statement)
        .where(
            models.StatementLine.category.is_not(None),
            models.Statement.profile_id == profile_id,
        )
        .distinct()
    ).scalars().all()
    categories = sorted({*category_catalog, *line_categories})

    min_date, max_date = db.execute(
        select(func.min(models.StatementLine.transaction_date), func.max(models.StatementLine.transaction_date))
        .select_from(models.StatementLine)
        .join(models.Statement)
        .where(models.Statement.profile_id == profile_id)
    ).one()

    return {
        "banks": list(banks),
        "categories": categories,
        "min_date": min_date,
        "max_date": max_date,
    }
