from __future__ import annotations

from pydantic import BaseModel


class SeriesPoint(BaseModel):
    bucket: str
    value: float


class BreakdownPoint(BaseModel):
    key: str
    value: float
