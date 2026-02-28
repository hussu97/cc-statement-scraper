from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ccs_platform.api.deps import ActorContext, get_db, require_operator_role
from ccs_platform.db import models
from ccs_platform.db.repositories import CategoryRepository
from ccs_platform.api.v1.schemas import (
    CategoryCreate,
    CategoryOut,
    CategoryRuleCreate,
    CategoryRuleOut,
    CategoryRuleTestRequest,
    CategoryRuleTestResponse,
    CategoryRuleUpdate,
    PaginatedCategoryRules,
)
from ccs_platform.domain.categorization.engine import categorize, ensure_category


router = APIRouter(tags=["categories"])


@router.get("/categories", response_model=list[CategoryOut])
def list_categories(db: Session = Depends(get_db)) -> list[CategoryOut]:
    rows = CategoryRepository(db).list_all_categories()
    return [CategoryOut.model_validate(row) for row in rows]


@router.post("/categories", response_model=CategoryOut)
def create_category(
    payload: CategoryCreate,
    db: Session = Depends(get_db),
    actor: ActorContext = Depends(require_operator_role),
) -> CategoryOut:
    category = ensure_category(db, payload.name)
    db.commit()
    db.refresh(category)
    return CategoryOut.model_validate(category)


@router.get("/category-rules", response_model=PaginatedCategoryRules)
def list_category_rules(
    db: Session = Depends(get_db),
    page: int = 1,
    page_size: int = 100,
    search: str | None = None,
) -> PaginatedCategoryRules:
    page = max(page, 1)
    page_size = min(max(page_size, 1), 1000)

    total, rows = CategoryRepository(db).list_rules_paginated(
        page=page, page_size=page_size, search=search
    )
    return PaginatedCategoryRules(
        total=total,
        page=page,
        page_size=page_size,
        items=[CategoryRuleOut.model_validate(row) for row in rows],
    )


@router.post("/category-rules", response_model=CategoryRuleOut)
def create_category_rule(
    payload: CategoryRuleCreate,
    db: Session = Depends(get_db),
    actor: ActorContext = Depends(require_operator_role),
) -> CategoryRuleOut:
    ensure_category(db, payload.category_name)

    row = models.CategoryRule(
        name=payload.name,
        category_name=payload.category_name,
        match_type=payload.match_type,
        pattern=payload.pattern,
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
    actor: ActorContext = Depends(require_operator_role),
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
    category, rule = categorize(db, merchant_normalized=payload.merchant_normalized)
    return CategoryRuleTestResponse(
        category=category,
        matched_rule_id=rule.id if rule else None,
        matched_rule_name=rule.name if rule else None,
    )
