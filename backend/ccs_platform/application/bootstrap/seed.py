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

    all_rule_sections = [
        rules_doc.get("global_rules", []),
        rules_doc.get("bank_rules", []),
        rules_doc.get("bank_card_rules", []),
    ]
    seed_index = 0
    for section in all_rule_sections:
        for rule in section:
            category = rule.get("category", "Uncategorized")
            ensure_category(db, category)
            for keyword in rule.get("keywords", []):
                pattern = str(keyword).upper()
                if not pattern:
                    continue
                db.add(
                    models.CategoryRule(
                        name=f"seed-{seed_index}-{pattern}",
                        category_name=category,
                        match_type=models.MatchType.CONTAINS,
                        pattern=pattern,
                        active=True,
                    )
                )
                seed_index += 1

    ensure_category(db, "Uncategorized")
    _merge_category_alias_if_unused(db, source="Groceries", target="Grocery")
    _merge_category_alias_if_unused(db, source="Subscriptions", target="Subscription")
    _merge_category_alias_if_unused(db, source="Online Shopping", target="Shopping")
    _merge_category_alias_if_unused(db, source="Fines", target="Fines/Govt Services")


def seed_defaults(db: Session) -> None:
    seed_banks(db)
    ensure_profile_seeds(db)
    seed_runtime_settings(db)
    _seed_categories_and_rules(db)
