from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
from ccs_platform.api.v1.schemas import (
    BreakdownPoint,
    DashboardFilterMetaResponse,
    DashboardOverviewOut,
    SeriesPoint,
    StackedSeriesResponse,
    TrendPoint,
    TrendSeriesResponse,
)
from ccs_platform.application.analytics import dashboard as dashboard_analytics
from ccs_platform.application.analytics.dashboard import DashboardFilters


router = APIRouter(prefix="/dashboard", tags=["dashboard"])


def _validate_date_range(date_from: date | None, date_to: date | None) -> None:
    if date_from and date_to and date_from > date_to:
        raise HTTPException(status_code=400, detail="date_from must be <= date_to")


def _filters(
    profile_id: int,
    *,
    bank_codes: list[str] | None = None,
    categories: list[str] | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    merchant_search: str | None = None,
    direction: str | None = None,
) -> DashboardFilters:
    return DashboardFilters(
        profile_id=profile_id,
        bank_codes=bank_codes,
        categories=categories,
        date_from=date_from,
        date_to=date_to,
        merchant_search=merchant_search,
        direction=direction,
    )


@router.get("/overview", response_model=DashboardOverviewOut)
def dashboard_overview(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    bank_codes: list[str] | None = Query(default=None),
    categories: list[str] | None = Query(default=None),
    date_from: date | None = None,
    date_to: date | None = None,
    merchant_search: str | None = None,
    direction: str | None = None,
) -> DashboardOverviewOut:
    _validate_date_range(date_from, date_to)
    payload = dashboard_analytics.fetch_overview(
        db,
        filters=_filters(
            profile_id=profile.profile_id,
            bank_codes=bank_codes,
            categories=categories,
            date_from=date_from,
            date_to=date_to,
            merchant_search=merchant_search,
            direction=direction,
        ),
    )
    return DashboardOverviewOut(**payload)


@router.get("/timeseries", response_model=list[SeriesPoint])
def dashboard_timeseries(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    bank_codes: list[str] | None = Query(default=None),
    categories: list[str] | None = Query(default=None),
    date_from: date | None = None,
    date_to: date | None = None,
    merchant_search: str | None = None,
    direction: str | None = None,
) -> list[SeriesPoint]:
    _validate_date_range(date_from, date_to)
    points = dashboard_analytics.fetch_trend_series(
        db,
        filters=_filters(
            profile_id=profile.profile_id,
            bank_codes=bank_codes,
            categories=categories,
            date_from=date_from,
            date_to=date_to,
            merchant_search=merchant_search,
            direction=direction,
        ),
    )
    return [SeriesPoint(bucket=str(point["bucket"]), value=float(point["net_aed"])) for point in points]


@router.get("/trend-series", response_model=TrendSeriesResponse)
def dashboard_trend_series(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    bank_codes: list[str] | None = Query(default=None),
    categories: list[str] | None = Query(default=None),
    date_from: date | None = None,
    date_to: date | None = None,
    merchant_search: str | None = None,
) -> TrendSeriesResponse:
    _validate_date_range(date_from, date_to)
    points = dashboard_analytics.fetch_trend_series(
        db,
        filters=_filters(
            profile_id=profile.profile_id,
            bank_codes=bank_codes,
            categories=categories,
            date_from=date_from,
            date_to=date_to,
            merchant_search=merchant_search,
        ),
    )
    return TrendSeriesResponse(points=[TrendPoint(**point) for point in points])


@router.get("/bank-trend-series", response_model=StackedSeriesResponse)
def dashboard_bank_trend_series(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    bank_codes: list[str] | None = Query(default=None),
    categories: list[str] | None = Query(default=None),
    date_from: date | None = None,
    date_to: date | None = None,
    merchant_search: str | None = None,
) -> StackedSeriesResponse:
    _validate_date_range(date_from, date_to)
    payload = dashboard_analytics.fetch_bank_trend_series(
        db,
        filters=_filters(
            profile_id=profile.profile_id,
            bank_codes=bank_codes,
            categories=categories,
            date_from=date_from,
            date_to=date_to,
            merchant_search=merchant_search,
        ),
    )
    return StackedSeriesResponse.model_validate(payload)


@router.get("/category-trend-series", response_model=StackedSeriesResponse)
def dashboard_category_trend_series(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    bank_codes: list[str] | None = Query(default=None),
    categories: list[str] | None = Query(default=None),
    date_from: date | None = None,
    date_to: date | None = None,
    merchant_search: str | None = None,
    top_n: int = Query(default=6, ge=1, le=20),
) -> StackedSeriesResponse:
    _validate_date_range(date_from, date_to)
    payload = dashboard_analytics.fetch_category_trend_series(
        db,
        filters=_filters(
            profile_id=profile.profile_id,
            bank_codes=bank_codes,
            categories=categories,
            date_from=date_from,
            date_to=date_to,
            merchant_search=merchant_search,
        ),
        top_n=top_n,
    )
    return StackedSeriesResponse.model_validate(payload)


@router.get("/filter-meta", response_model=DashboardFilterMetaResponse)
def dashboard_filter_meta(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> DashboardFilterMetaResponse:
    payload = dashboard_analytics.fetch_filter_meta(db, profile_id=profile.profile_id)
    return DashboardFilterMetaResponse.model_validate(payload)


@router.get("/category-breakdown", response_model=list[BreakdownPoint])
def dashboard_category_breakdown(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    bank_codes: list[str] | None = Query(default=None),
    categories: list[str] | None = Query(default=None),
    date_from: date | None = None,
    date_to: date | None = None,
    merchant_search: str | None = None,
):
    _validate_date_range(date_from, date_to)
    points = dashboard_analytics.fetch_category_breakdown(
        db,
        filters=_filters(
            profile_id=profile.profile_id,
            bank_codes=bank_codes,
            categories=categories,
            date_from=date_from,
            date_to=date_to,
            merchant_search=merchant_search,
        ),
    )
    return [BreakdownPoint(**point) for point in points]


@router.get("/top-merchants", response_model=list[BreakdownPoint])
def dashboard_top_merchants(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    bank_codes: list[str] | None = Query(default=None),
    categories: list[str] | None = Query(default=None),
    date_from: date | None = None,
    date_to: date | None = None,
    merchant_search: str | None = None,
    limit: int = 20,
):
    _validate_date_range(date_from, date_to)
    points = dashboard_analytics.fetch_top_merchants(
        db,
        filters=_filters(
            profile_id=profile.profile_id,
            bank_codes=bank_codes,
            categories=categories,
            date_from=date_from,
            date_to=date_to,
            merchant_search=merchant_search,
        ),
        limit=limit,
    )
    return [BreakdownPoint(**point) for point in points]


@router.get("/bank-breakdown", response_model=list[BreakdownPoint])
def dashboard_bank_breakdown(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    bank_codes: list[str] | None = Query(default=None),
    categories: list[str] | None = Query(default=None),
    date_from: date | None = None,
    date_to: date | None = None,
    merchant_search: str | None = None,
):
    _validate_date_range(date_from, date_to)
    points = dashboard_analytics.fetch_bank_breakdown(
        db,
        filters=_filters(
            profile_id=profile.profile_id,
            bank_codes=bank_codes,
            categories=categories,
            date_from=date_from,
            date_to=date_to,
            merchant_search=merchant_search,
        ),
    )
    return [BreakdownPoint(**point) for point in points]
