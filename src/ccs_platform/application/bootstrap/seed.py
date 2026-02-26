from __future__ import annotations

from sqlalchemy import delete
from sqlalchemy import select
from sqlalchemy import update
from sqlalchemy.orm import Session

from ccs_platform.core.bank_config import load_app_config
from ccs_platform.db import models
from ccs_platform.application.banks.capabilities import seed_banks
from ccs_platform.application.profiles.service import ensure_profile_seeds
from ccs_platform.application.bootstrap.runtime_settings_seed import seed_runtime_settings
from ccs_platform.domain.categorization.engine import ensure_category


def _merge_category_alias_if_unused(
    db: Session,
    *,
    source: str,
    target: str,
) -> None:
    source_name = source.strip()
    target_name = target.strip()
    if not source_name or not target_name or source_name == target_name:
        return

    source_rule = db.execute(
        select(models.CategoryRule.id).where(models.CategoryRule.category_name == source_name).limit(1)
    ).scalar_one_or_none()
    if source_rule is not None:
        return

    ensure_category(db, target_name)
    db.execute(
        update(models.StatementLine)
        .where(models.StatementLine.category == source_name)
        .values(category=target_name)
    )
    db.execute(delete(models.Category).where(models.Category.name == source_name))


def _seed_categories_and_rules(db: Session) -> None:
    app_cfg = load_app_config()
    rules_doc = app_cfg.category_rules

    # Keep user-managed rules, but refresh YAML-backed seed rules on every startup.
    db.execute(delete(models.CategoryRule).where(models.CategoryRule.name.like("seed-%")))

    priority = 10

    for rule in rules_doc.get("bank_card_rules", []):
        category = rule.get("category", "Uncategorized")
        ensure_category(db, category)
        bank_code = str(rule.get("bank", "")).upper() or None
        card_last4 = str(rule.get("card_last4", "")).strip() or None
        for keyword in rule.get("keywords", []):
            db.add(
                models.CategoryRule(
                    name=f"seed-bank-card-{bank_code}-{card_last4}-{keyword}",
                    category_name=category,
                    match_type=models.MatchType.CONTAINS,
                    pattern=str(keyword).upper(),
                    bank_code=bank_code,
                    card_last4=card_last4,
                    priority=priority,
                    active=True,
                )
            )
            priority += 1

    for rule in rules_doc.get("bank_rules", []):
        category = rule.get("category", "Uncategorized")
        ensure_category(db, category)
        bank_code = str(rule.get("bank", "")).upper() or None
        for keyword in rule.get("keywords", []):
            db.add(
                models.CategoryRule(
                    name=f"seed-bank-{bank_code}-{keyword}",
                    category_name=category,
                    match_type=models.MatchType.CONTAINS,
                    pattern=str(keyword).upper(),
                    bank_code=bank_code,
                    card_last4=None,
                    priority=priority,
                    active=True,
                )
            )
            priority += 1

    for rule in rules_doc.get("global_rules", []):
        category = rule.get("category", "Uncategorized")
        ensure_category(db, category)
        for keyword in rule.get("keywords", []):
            db.add(
                models.CategoryRule(
                    name=f"seed-global-{keyword}",
                    category_name=category,
                    match_type=models.MatchType.CONTAINS,
                    pattern=str(keyword).upper(),
                    bank_code=None,
                    card_last4=None,
                    priority=priority,
                    active=True,
                )
            )
            priority += 1

    ensure_category(db, "Uncategorized")
    _merge_category_alias_if_unused(db, source="Groceries", target="Grocery")


def seed_defaults(db: Session) -> None:
    seed_banks(db)
    ensure_profile_seeds(db)
    seed_runtime_settings(db)
    _seed_categories_and_rules(db)
