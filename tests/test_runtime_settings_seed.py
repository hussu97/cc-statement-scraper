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
        profile = models.Profile(key="hussain", name="Hussain", is_default=True)
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
        profile = models.Profile(key="hussain", name="Hussain", is_default=True)
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
                "HUSSAIN_FAB_USERNAME=hussain-fab-user",
                "HUSSAIN_ENBD_USERNAME=hussain-enbd-user",
                "TEJASVIE_MASHREQ_USERNAME=tejasvie-mashreq-user",
                "TEJASVIE_MASHREQ_PASSWORD=tejasvie-mashreq-pass",
                "TEJASVIE_CCS_DOWNLOADS_DIR=/tmp/tejasvie-downloads",
            ]
        ),
        encoding="utf-8",
    )

    with _session() as db:
        hussain = models.Profile(key="hussain", name="Hussain", is_default=True)
        tejasvie = models.Profile(key="tejasvie", name="Tejasvie", is_default=False)
        db.add_all([hussain, tejasvie])
        db.flush()

        hussain_result = seed_runtime_settings_from_env(
            db,
            profile_id=hussain.id,
            profile_key=hussain.key,
            env_file=env_path,
            source_mode="env_file",
            blank_values=False,
        )
        tejasvie_result = seed_runtime_settings_from_env(
            db,
            profile_id=tejasvie.id,
            profile_key=tejasvie.key,
            env_file=env_path,
            source_mode="env_file",
            blank_values=True,
        )
        db.flush()

        assert hussain_result["profile_key"] == "hussain"
        assert tejasvie_result["profile_key"] == "tejasvie"

        rows = db.execute(select(models.RuntimeSetting)).scalars().all()
        by_profile_key = {(row.profile_id, row.key): row for row in rows}

        assert by_profile_key[(hussain.id, "FAB_USERNAME")].value == "hussain-fab-user"
        assert by_profile_key[(hussain.id, "ENBD_USERNAME")].value == "hussain-enbd-user"
        # Non-default profile with blank_values only accepts explicit TEJASVIE_* keys.
        assert by_profile_key[(tejasvie.id, "MASHREQ_USERNAME")].value == "tejasvie-mashreq-user"
        assert by_profile_key[(tejasvie.id, "MASHREQ_PASSWORD")].value == "tejasvie-mashreq-pass"
        assert by_profile_key[(tejasvie.id, "FAB_USERNAME")].value == ""
