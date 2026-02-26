from __future__ import annotations

from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from ccs_platform.application.profiles.service import ensure_profile_seeds
from ccs_platform.db import Base, models


def _session():
    engine = create_engine("sqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine, future=True)
    return Session()


def test_profile_seed_assigns_secondary_defaults_to_bob_only() -> None:
    with _session() as db:
        for code in ["FAB", "ADCB", "ENBD", "EIB", "SIB", "MASHREQ"]:
            db.add(
                models.Bank(
                    code=code,
                    name=code,
                    supports_historical_month_selection=True,
                    supports_multi_month=True,
                    supports_headless=True,
                )
            )
        db.flush()

        ensure_profile_seeds(db)
        db.flush()

        profiles = {
            profile.key: profile
            for profile in db.execute(select(models.Profile)).scalars().all()
        }
        assert {"alice", "bob"}.issubset(profiles.keys())

        alice = profiles["alice"]
        bob = profiles["bob"]

        alice_banks = set(
            db.execute(
                select(models.ProfileBank.bank_code).where(models.ProfileBank.profile_id == alice.id)
            ).scalars().all()
        )
        bob_banks = set(
            db.execute(
                select(models.ProfileBank.bank_code).where(models.ProfileBank.profile_id == bob.id)
            ).scalars().all()
        )

        assert alice_banks == {"FAB", "ADCB", "ENBD", "SIB"}
        assert bob_banks == {"MASHREQ", "EIB"}


def test_profile_seed_backfills_new_secondary_bank_for_existing_profile() -> None:
    with _session() as db:
        for code in ["FAB", "ADCB", "ENBD", "EIB", "SIB", "MASHREQ"]:
            db.add(
                models.Bank(
                    code=code,
                    name=code,
                    supports_historical_month_selection=True,
                    supports_multi_month=True,
                    supports_headless=True,
                )
            )
        db.flush()

        alice = models.Profile(key="alice", name="Alice", is_default=True)
        bob = models.Profile(key="bob", name="Bob", is_default=False)
        db.add_all([alice, bob])
        db.flush()

        for bank_code in ("FAB", "ADCB", "ENBD", "SIB"):
            db.add(models.ProfileBank(profile_id=alice.id, bank_code=bank_code))
        db.add(models.ProfileBank(profile_id=bob.id, bank_code="MASHREQ"))
        db.flush()

        ensure_profile_seeds(db)
        db.flush()

        bob_banks = set(
            db.execute(
                select(models.ProfileBank.bank_code).where(models.ProfileBank.profile_id == bob.id)
            ).scalars().all()
        )

        assert bob_banks == {"MASHREQ", "EIB"}
