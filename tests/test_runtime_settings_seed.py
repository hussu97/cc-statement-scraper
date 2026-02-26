from __future__ import annotations

import os

from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from ccs_platform.core.runtime_settings import apply_runtime_settings_to_process_env, seed_runtime_settings_from_env
from ccs_platform.db import Base, models


def _session():
    engine = create_engine("sqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine, future=True)
    return Session()


def test_seed_runtime_settings_from_env_file_and_apply(monkeypatch, tmp_path) -> None:
    env_path = tmp_path / ".env"
    env_path.write_text(
        "\n".join(
            [
                "FAB_USERNAME=user-fab",
                "FAB_PASSWORD=pass-fab",
                "ADCB_CID=cid-adcb",
                "ENBD_USERNAME=user-enbd",
                "EIB_USERNAME=user-eib",
                "SIB_USER_ID=user-sib",
                "MASHREQ_USERNAME=user-mashreq",
                "CCS_DOWNLOADS_DIR=/tmp/downloads",
            ]
        ),
        encoding="utf-8",
    )

    with _session() as db:
        profile = models.Profile(key="alice", name="Alice", is_default=True)
        db.add(profile)
        db.flush()

        monkeypatch.setenv("FAB_USERNAME", "env-wins")
        result = seed_runtime_settings_from_env(db, profile_id=profile.id, env_file=env_path)
        db.flush()

        assert result["inserted"] >= 5

        rows = db.execute(select(models.RuntimeSetting)).scalars().all()
        by_key = {row.key: row for row in rows}
        assert by_key["FAB_USERNAME"].value == "env-wins"
        assert by_key["FAB_PASSWORD"].is_secret is True
        assert by_key["SIB_USER_ID"].value == "user-sib"
        assert by_key["EIB_USERNAME"].value == "user-eib"
        assert by_key["MASHREQ_USERNAME"].value == "user-mashreq"
        assert by_key["CCS_DOWNLOADS_DIR"].is_secret is False

        monkeypatch.setenv("FAB_USERNAME", "stale-value")
        applied = apply_runtime_settings_to_process_env(db, profile_id=profile.id)
        assert applied >= 1
        assert os.getenv("FAB_USERNAME") == "env-wins"


def test_seed_runtime_settings_none_source_mode_keeps_blank_values(tmp_path) -> None:
    env_path = tmp_path / ".env"
    env_path.write_text("FAB_USERNAME=user-fab\n", encoding="utf-8")

    with _session() as db:
        profile = models.Profile(key="alice", name="Alice", is_default=True)
        db.add(profile)
        db.flush()

        result = seed_runtime_settings_from_env(
            db,
            profile_id=profile.id,
            env_file=env_path,
            source_mode="none",
        )
        db.flush()

        assert result["source_mode"] == "none"
        rows = db.execute(select(models.RuntimeSetting)).scalars().all()
        by_key = {row.key: row for row in rows}
        assert by_key["FAB_USERNAME"].value == ""


def test_seed_runtime_settings_supports_profile_scoped_env_keys(tmp_path) -> None:
    env_path = tmp_path / ".env"
    env_path.write_text(
        "\n".join(
            [
                "FAB_USERNAME=legacy-fallback",
                "ALICE_FAB_USERNAME=alice-fab-user",
                "ALICE_ENBD_USERNAME=alice-enbd-user",
                "BOB_MASHREQ_USERNAME=bob-mashreq-user",
                "BOB_MASHREQ_PASSWORD=bob-mashreq-pass",
                "BOB_CCS_DOWNLOADS_DIR=/tmp/bob-downloads",
            ]
        ),
        encoding="utf-8",
    )

    with _session() as db:
        alice = models.Profile(key="alice", name="Alice", is_default=True)
        bob = models.Profile(key="bob", name="Bob", is_default=False)
        db.add_all([alice, bob])
        db.flush()

        alice_result = seed_runtime_settings_from_env(
            db,
            profile_id=alice.id,
            profile_key=alice.key,
            env_file=env_path,
            source_mode="env_file",
            blank_values=False,
        )
        bob_result = seed_runtime_settings_from_env(
            db,
            profile_id=bob.id,
            profile_key=bob.key,
            env_file=env_path,
            source_mode="env_file",
            blank_values=True,
        )
        db.flush()

        assert alice_result["profile_key"] == "alice"
        assert bob_result["profile_key"] == "bob"

        rows = db.execute(select(models.RuntimeSetting)).scalars().all()
        by_profile_key = {(row.profile_id, row.key): row for row in rows}

        assert by_profile_key[(alice.id, "FAB_USERNAME")].value == "alice-fab-user"
        assert by_profile_key[(alice.id, "ENBD_USERNAME")].value == "alice-enbd-user"
        # Non-default profile with blank_values only accepts explicit BOB_* keys.
        assert by_profile_key[(bob.id, "MASHREQ_USERNAME")].value == "bob-mashreq-user"
        assert by_profile_key[(bob.id, "MASHREQ_PASSWORD")].value == "bob-mashreq-pass"
        assert by_profile_key[(bob.id, "FAB_USERNAME")].value == ""
