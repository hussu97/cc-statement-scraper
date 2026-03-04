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


def _fetch_active_rules(db: Session) -> list[models.CategoryRule]:
    return list(
        db.execute(
            select(models.CategoryRule)
            .where(models.CategoryRule.active.is_(True))
            .order_by(models.CategoryRule.id.asc())
        ).scalars()
    )


def find_best_rule(
    rules: list[models.CategoryRule],
    merchant_normalized: str,
) -> models.CategoryRule | None:
    """Select the best matching rule from a pre-fetched list — no DB query."""
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


def find_matching_rule(
    db: Session,
    *,
    merchant_normalized: str,
) -> models.CategoryRule | None:
    return find_best_rule(_fetch_active_rules(db), merchant_normalized)


def categorize(
    db: Session,
    *,
    merchant_normalized: str,
) -> tuple[str, models.CategoryRule | None]:
    rule = find_matching_rule(db, merchant_normalized=merchant_normalized)
    if rule:
        ensure_category(db, rule.category_name)
        return rule.category_name, rule

    ensure_category(db, "Uncategorized")
    return "Uncategorized", None


def apply_override_if_exists(
    db: Session,
    *,
    fingerprint: str | None,
    line: models.StatementLine,
) -> bool:
    """Set line.category and line.category_override from the overrides table if one exists.
    Returns True if an override was applied."""
    if not fingerprint:
        return False
    override = db.execute(
        select(models.CategoryOverride).where(models.CategoryOverride.fingerprint == fingerprint)
    ).scalar_one_or_none()
    if override:
        ensure_category(db, override.category_name)
        line.category = override.category_name
        line.category_override = override.category_name
        return True
    return False


def reclassify_statement_lines(
    db: Session,
    statement_ids: list[int] | None = None,
    *,
    profile_id: int | None = None,
) -> int:
    # Fetch all active rules once — avoids an N+1 query per statement line.
    active_rules = _fetch_active_rules(db)

    query = select(models.StatementLine, models.Statement).join(models.Statement)
    if profile_id is not None:
        query = query.where(models.Statement.profile_id == profile_id)
    if statement_ids:
        query = query.where(models.StatementLine.statement_id.in_(statement_ids))

    updated = 0
    for line, _statement in db.execute(query).all():
        if line.category_override is not None:
            continue
        rule = find_best_rule(active_rules, line.merchant_normalized)
        category = rule.category_name if rule else "Uncategorized"
        if rule:
            ensure_category(db, rule.category_name)
        if line.category != category:
            line.category = category
            updated += 1
    return updated
