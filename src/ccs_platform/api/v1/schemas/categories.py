from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict

from ccs_platform.db.models import MatchType


class CategoryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    created_at: datetime


class CategoryCreate(BaseModel):
    name: str


class CategoryRuleOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    category_name: str
    match_type: MatchType
    pattern: str
    bank_code: str | None
    card_last4: str | None
    priority: int
    active: bool
    created_at: datetime
    updated_at: datetime


class CategoryRuleCreate(BaseModel):
    name: str
    category_name: str
    match_type: MatchType = MatchType.CONTAINS
    pattern: str
    bank_code: str | None = None
    card_last4: str | None = None
    priority: int = 100
    active: bool = True


class CategoryRuleUpdate(BaseModel):
    name: str | None = None
    category_name: str | None = None
    match_type: MatchType | None = None
    pattern: str | None = None
    bank_code: str | None = None
    card_last4: str | None = None
    priority: int | None = None
    active: bool | None = None


class CategoryRuleTestRequest(BaseModel):
    bank_code: str
    card_last4: str | None = None
    merchant_normalized: str


class CategoryRuleTestResponse(BaseModel):
    category: str
    matched_rule_id: int | None
    matched_rule_name: str | None
