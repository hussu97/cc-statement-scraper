from __future__ import annotations

import re

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.db import models


def ensure_category(db: Session, category_name: str) -> models.Category:
    normalized = category_name.strip() or "Uncategorized"
    existing = db.execute(
        select(models.Category).where(models.Category.name == normalized)
    ).scalar_one_or_none()
    if existing:
        return existing
    created = models.Category(name=normalized)
    db.add(created)
    db.flush()
    return created


def _match(rule: models.CategoryRule, merchant_normalized: str) -> bool:
    text = merchant_normalized.upper().strip()
    pattern = (rule.pattern or "").strip()
    if not pattern:
        return False

    if rule.match_type == models.MatchType.CONTAINS:
        return pattern.upper() in text
    if rule.match_type == models.MatchType.EXACT:
        return text == pattern.upper()
    if rule.match_type == models.MatchType.REGEX:
        return bool(re.search(pattern, text, re.IGNORECASE))
    return False


def find_matching_rule(
    db: Session,
    *,
    bank_code: str,
    card_last4: str | None,
    merchant_normalized: str,
) -> models.CategoryRule | None:
    rules = db.execute(
        select(models.CategoryRule)
        .where(models.CategoryRule.active.is_(True))
        .order_by(models.CategoryRule.priority.asc(), models.CategoryRule.id.asc())
    ).scalars()

    for rule in rules:
        if rule.bank_code and rule.bank_code.upper() != bank_code.upper():
            continue
        if rule.card_last4 and (card_last4 or "") != rule.card_last4:
            continue
        if _match(rule, merchant_normalized):
            return rule
    return None


def categorize(
    db: Session,
    *,
    bank_code: str,
    card_last4: str | None,
    merchant_normalized: str,
) -> tuple[str, models.CategoryRule | None]:
    rule = find_matching_rule(
        db,
        bank_code=bank_code,
        card_last4=card_last4,
        merchant_normalized=merchant_normalized,
    )
    if rule:
        ensure_category(db, rule.category_name)
        return rule.category_name, rule

    ensure_category(db, "Uncategorized")
    return "Uncategorized", None


def reclassify_statement_lines(
    db: Session,
    statement_ids: list[int] | None = None,
    *,
    profile_id: int | None = None,
) -> int:
    query = select(models.StatementLine, models.Statement).join(models.Statement)
    if profile_id is not None:
        query = query.where(models.Statement.profile_id == profile_id)
    if statement_ids:
        query = query.where(models.StatementLine.statement_id.in_(statement_ids))

    updated = 0
    for line, statement in db.execute(query).all():
        category, _ = categorize(
            db,
            bank_code=statement.bank_code,
            card_last4=line.card_last4,
            merchant_normalized=line.merchant_normalized,
        )
        if line.category != category:
            line.category = category
            updated += 1
    return updated
