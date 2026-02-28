from __future__ import annotations

from datetime import date

from pydantic import BaseModel


class DashboardOverviewOut(BaseModel):
    total_spend_aed: float
    total_credits_aed: float
    uncategorized_count: int
    uncategorized_ratio: float
    statement_count: int
    mom_delta_pct: float | None


class TrendPoint(BaseModel):
    bucket: str
    debit_aed: float
    credit_aed: float
    net_aed: float


class TrendSeriesResponse(BaseModel):
    points: list[TrendPoint]


class StackedSeriesPoint(BaseModel):
    bucket: str
    value_aed: float


class StackedSeries(BaseModel):
    key: str
    points: list[StackedSeriesPoint]


class StackedSeriesResponse(BaseModel):
    buckets: list[str]
    series: list[StackedSeries]


class DashboardFilterMetaResponse(BaseModel):
    banks: list[str]
    categories: list[str]
    min_date: date | None
    max_date: date | None
