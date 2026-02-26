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


def _specificity_score(pattern: str) -> int:
    return sum(1 for ch in pattern if ch.isalnum())


def _match_type_tiebreaker(match_type: models.MatchType) -> int:
    if match_type == models.MatchType.EXACT:
        return 3
    if match_type == models.MatchType.CONTAINS:
        return 2
    if match_type == models.MatchType.REGEX:
        return 1
    return 0


def find_matching_rule(
    db: Session,
    *,
    bank_code: str | None = None,
    card_last4: str | None = None,
    merchant_normalized: str,
) -> models.CategoryRule | None:
    rules = db.execute(
        select(models.CategoryRule)
        .where(models.CategoryRule.active.is_(True))
        .order_by(models.CategoryRule.id.asc())
    ).scalars()

    best_rule: models.CategoryRule | None = None
    best_specificity = -1
    best_type_tiebreaker = -1

    for rule in rules:
        if not _match(rule, merchant_normalized):
            continue
        specificity = _specificity_score((rule.pattern or "").strip())
        type_tiebreaker = _match_type_tiebreaker(rule.match_type)
        if specificity > best_specificity:
            best_rule = rule
            best_specificity = specificity
            best_type_tiebreaker = type_tiebreaker
            continue
        if specificity == best_specificity and type_tiebreaker > best_type_tiebreaker:
            best_rule = rule
            best_type_tiebreaker = type_tiebreaker

    return best_rule


def categorize(
    db: Session,
    *,
    bank_code: str | None = None,
    card_last4: str | None = None,
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
