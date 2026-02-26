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
                "SIB_USER_ID=user-sib",
                "CCS_DOWNLOADS_DIR=/tmp/downloads",
            ]
        ),
        encoding="utf-8",
    )

    with _session() as db:
        profile = models.Profile(key="hussain", name="Hussain", is_default=True)
        db.add(profile)
        db.flush()

        result = seed_runtime_settings_from_env(db, profile_id=profile.id, env_file=env_path)
        db.flush()

        assert result["inserted"] >= 5

        rows = db.execute(select(models.RuntimeSetting)).scalars().all()
        by_key = {row.key: row for row in rows}
        assert by_key["FAB_USERNAME"].value == "user-fab"
        assert by_key["FAB_PASSWORD"].is_secret is True
        assert by_key["SIB_USER_ID"].value == "user-sib"
        assert by_key["CCS_DOWNLOADS_DIR"].is_secret is False

        monkeypatch.setenv("FAB_USERNAME", "stale-value")
        applied = apply_runtime_settings_to_process_env(db, profile_id=profile.id)
        assert applied >= 1
        assert os.getenv("FAB_USERNAME") == "user-fab"
