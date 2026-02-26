from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict


class RuntimeSettingOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    key: str
    value: str
    bank_code: str | None
    is_secret: bool
    description: str | None
    created_at: datetime
    updated_at: datetime


class PaginatedRuntimeSettings(BaseModel):
    total: int
    page: int
    page_size: int
    items: list[RuntimeSettingOut]


class RuntimeSettingCreate(BaseModel):
    key: str
    value: str = ""
    bank_code: str | None = None
    is_secret: bool | None = None
    description: str | None = None


class RuntimeSettingUpdate(BaseModel):
    value: str
    bank_code: str | None = None
    is_secret: bool | None = None
    description: str | None = None


class RuntimeSettingsSeedRequest(BaseModel):
    overwrite_existing: bool = False
