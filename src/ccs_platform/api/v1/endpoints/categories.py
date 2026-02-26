from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.api.deps import get_db
from ccs_platform.api.v1.schemas import (
    CategoryCreate,
    CategoryOut,
    CategoryRuleCreate,
    CategoryRuleOut,
    CategoryRuleTestRequest,
    CategoryRuleTestResponse,
    CategoryRuleUpdate,
)
from ccs_platform.domain.categorization.engine import categorize, ensure_category


router = APIRouter(tags=["categories"])


@router.get("/categories", response_model=list[CategoryOut])
def list_categories(db: Session = Depends(get_db)) -> list[CategoryOut]:
    rows = db.execute(select(models.Category).order_by(models.Category.name.asc())).scalars().all()
    return [CategoryOut.model_validate(row) for row in rows]


@router.post("/categories", response_model=CategoryOut)
def create_category(payload: CategoryCreate, db: Session = Depends(get_db)) -> CategoryOut:
    category = ensure_category(db, payload.name)
    db.commit()
    db.refresh(category)
    return CategoryOut.model_validate(category)


@router.get("/category-rules", response_model=list[CategoryRuleOut])
def list_category_rules(db: Session = Depends(get_db)) -> list[CategoryRuleOut]:
    rows = db.execute(
        select(models.CategoryRule).order_by(models.CategoryRule.priority.asc(), models.CategoryRule.id.asc())
    ).scalars().all()
    return [CategoryRuleOut.model_validate(row) for row in rows]


@router.post("/category-rules", response_model=CategoryRuleOut)
def create_category_rule(
    payload: CategoryRuleCreate,
    db: Session = Depends(get_db),
) -> CategoryRuleOut:
    ensure_category(db, payload.category_name)

    row = models.CategoryRule(
        name=payload.name,
        category_name=payload.category_name,
        match_type=payload.match_type,
        pattern=payload.pattern,
        bank_code=payload.bank_code.upper() if payload.bank_code else None,
        card_last4=payload.card_last4,
        priority=payload.priority,
        active=payload.active,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return CategoryRuleOut.model_validate(row)


@router.patch("/category-rules/{rule_id}", response_model=CategoryRuleOut)
def patch_category_rule(
    rule_id: int,
    payload: CategoryRuleUpdate,
    db: Session = Depends(get_db),
) -> CategoryRuleOut:
    row = db.get(models.CategoryRule, rule_id)
    if not row:
        raise HTTPException(status_code=404, detail="Rule not found")

    updates = payload.model_dump(exclude_unset=True)
    if "category_name" in updates:
        ensure_category(db, updates["category_name"])

    for key, value in updates.items():
        setattr(row, key, value)

    db.commit()
    db.refresh(row)
    return CategoryRuleOut.model_validate(row)


@router.post("/category-rules/test", response_model=CategoryRuleTestResponse)
def test_category_rule(
    payload: CategoryRuleTestRequest,
    db: Session = Depends(get_db),
) -> CategoryRuleTestResponse:
    category, rule = categorize(
        db,
        bank_code=payload.bank_code.upper(),
        card_last4=payload.card_last4,
        merchant_normalized=payload.merchant_normalized,
    )
    return CategoryRuleTestResponse(
        category=category,
        matched_rule_id=rule.id if rule else None,
        matched_rule_name=rule.name if rule else None,
    )
