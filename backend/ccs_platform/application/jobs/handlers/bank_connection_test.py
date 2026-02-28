from __future__ import annotations

import os
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.db import models


def handle_bank_connection_test_job(db: Session, job: models.Job) -> dict[str, Any]:
    payload = job.payload_json or {}
    bank_code = str(payload.get("bank_code", "")).upper()
    mapping = db.execute(
        select(models.ProfileBank).where(
            models.ProfileBank.profile_id == job.profile_id,
            models.ProfileBank.bank_code == bank_code,
        )
    ).scalar_one_or_none()
    if mapping is None:
        raise RuntimeError(f"Bank {bank_code} is not enabled for this profile")

    required_env_map = {
        "FAB": ["FAB_USERNAME", "FAB_PASSWORD"],
        "ADCB": ["ADCB_CID", "ADCB_LOGIN_PASSWORD"],
        "ENBD": ["ENBD_USERNAME", "ENBD_PASSWORD"],
        "EIB": ["EIB_USERNAME", "EIB_PASSWORD"],
        "SIB": ["SIB_USER_ID", "SIB_PASSWORD", "SIB_PDF_PASSWORD"],
        "MASHREQ": ["MASHREQ_USERNAME", "MASHREQ_PASSWORD"],
    }
    required_env = required_env_map.get(bank_code)
    if not required_env:
        raise RuntimeError(f"Unsupported bank_code: {bank_code}")

    missing = [env for env in required_env if not os.getenv(env)]
    status = "ok" if not missing else "missing_env"
    return {
        "bank_code": bank_code,
        "status": status,
        "missing_env": missing,
    }
