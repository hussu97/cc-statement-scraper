from __future__ import annotations

from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import sessionmaker
from sqlalchemy import create_engine

from ccs_platform.application.bootstrap import seed as seed_module
from ccs_platform.core.bank_config import AppConfig, Paths
from ccs_platform.db import Base, models


def _session():
    engine = create_engine("sqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine, future=True)
    return Session()


def _fake_app_config() -> AppConfig:
    root = Path("/tmp/ccs-platform-test")
    paths = Paths(
        root=root,
        config_dir=root,
        data_dir=root,
        incoming_dir=root,
        archive_dir=root,
        output_dir=root,
        state_dir=root,
        downloads_dir=root,
    )
    return AppConfig(
        banks={},
        category_rules={
            "bank_card_rules": [],
            "bank_rules": [],
            "global_rules": [
                {"category": "Online Shopping", "keywords": ["TEMU.COM"]},
                {"category": "Grocery", "keywords": ["GROCERY"]},
            ],
        },
        paths=paths,
    )


def test_seed_categories_rules_refreshes_seeded_rules_but_keeps_manual(monkeypatch) -> None:
    with _session() as db:
        db.add(models.Category(name="Legacy"))
        db.add(models.Category(name="Other"))
        db.add(models.Category(name="Groceries"))
        db.add(models.Category(name="Subscriptions"))
        db.add(models.Category(name="Fines"))
        db.add(
            models.CategoryRule(
                name="seed-global-OLD",
                category_name="Legacy",
                match_type=models.MatchType.CONTAINS,
                pattern="OLD",
                bank_code=None,
                card_last4=None,
                priority=5,
                active=True,
            )
        )
        db.add(
            models.CategoryRule(
                name="manual-rule",
                category_name="Other",
                match_type=models.MatchType.CONTAINS,
                pattern="MANUAL",
                bank_code=None,
                card_last4=None,
                priority=500,
                active=True,
            )
        )
        db.commit()

        monkeypatch.setattr(seed_module, "load_app_config", _fake_app_config)

        seed_module._seed_categories_and_rules(db)
        db.commit()

        rules = db.execute(select(models.CategoryRule).order_by(models.CategoryRule.id.asc())).scalars().all()
        rule_names = {rule.name for rule in rules}
        seeded_patterns = {rule.pattern for rule in rules if rule.name.startswith("seed-")}

        assert "manual-rule" in rule_names
        assert "seed-global-OLD" not in rule_names
        assert "TEMU.COM" in seeded_patterns
        assert "GROCERY" in seeded_patterns
        category_names = {name for (name,) in db.execute(select(models.Category.name)).all()}
        assert "Grocery" in category_names
        assert "Groceries" not in category_names
        assert "Subscription" in category_names
        assert "Subscriptions" not in category_names
        assert "Fines/Govt Services" in category_names
        assert "Fines" not in category_names

        seeded_count = len([name for name in rule_names if name.startswith("seed-")])
        assert all(rule.bank_code is None for rule in rules)
        assert all(rule.card_last4 is None for rule in rules)
        assert all(rule.priority == 100 for rule in rules)

        seed_module._seed_categories_and_rules(db)
        db.commit()

        rules_after_second_seed = db.execute(select(models.CategoryRule)).scalars().all()
        seeded_count_after_second_seed = len([rule for rule in rules_after_second_seed if rule.name.startswith("seed-")])
        assert seeded_count_after_second_seed == seeded_count
