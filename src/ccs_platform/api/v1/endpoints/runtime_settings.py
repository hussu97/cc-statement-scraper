from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
from ccs_platform.api.v1.schemas import (
    RuntimeSettingCreate,
    RuntimeSettingOut,
    RuntimeSettingsSeedRequest,
    RuntimeSettingUpdate,
)
from ccs_platform.core.runtime_settings import (
    apply_runtime_settings_to_process_env,
    normalize_runtime_key,
    seed_runtime_settings_from_env,
    upsert_runtime_setting,
)
from ccs_platform.db import models


router = APIRouter(prefix="/runtime-settings", tags=["runtime-settings"])


@router.get("", response_model=list[RuntimeSettingOut])
def list_runtime_settings(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> list[RuntimeSettingOut]:
    rows = db.execute(
        select(models.RuntimeSetting)
        .where(models.RuntimeSetting.profile_id == profile.profile_id)
        .order_by(models.RuntimeSetting.bank_code.asc(), models.RuntimeSetting.key.asc())
    ).scalars().all()
    return [RuntimeSettingOut.model_validate(row) for row in rows]


@router.post("", response_model=RuntimeSettingOut)
def create_or_update_runtime_setting(
    payload: RuntimeSettingCreate,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> RuntimeSettingOut:
    row = upsert_runtime_setting(
        db,
        profile_id=profile.profile_id,
        key=payload.key,
        value=payload.value,
        bank_code=payload.bank_code,
        is_secret=payload.is_secret,
        description=payload.description,
    )
    db.commit()
    db.refresh(row)
    apply_runtime_settings_to_process_env(db, profile_id=profile.profile_id)
    return RuntimeSettingOut.model_validate(row)


@router.patch("/{key}", response_model=RuntimeSettingOut)
def patch_runtime_setting(
    key: str,
    payload: RuntimeSettingUpdate,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> RuntimeSettingOut:
    normalized_key = normalize_runtime_key(key)
    row = db.execute(
        select(models.RuntimeSetting).where(
            models.RuntimeSetting.profile_id == profile.profile_id,
            models.RuntimeSetting.key == normalized_key,
        )
    ).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail=f"Runtime setting not found: {normalized_key}")

    row = upsert_runtime_setting(
        db,
        profile_id=profile.profile_id,
        key=normalized_key,
        value=payload.value,
        bank_code=payload.bank_code,
        is_secret=payload.is_secret,
        description=payload.description,
    )
    db.commit()
    db.refresh(row)
    apply_runtime_settings_to_process_env(db, profile_id=profile.profile_id)
    return RuntimeSettingOut.model_validate(row)


@router.post("/seed-from-env")
def seed_runtime_settings(
    payload: RuntimeSettingsSeedRequest,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> dict[str, object]:
    result = seed_runtime_settings_from_env(
        db,
        profile_id=profile.profile_id,
        overwrite_existing=payload.overwrite_existing,
        blank_values=profile.profile_key != "alice",
    )
    db.commit()
    applied = apply_runtime_settings_to_process_env(db, profile_id=profile.profile_id)
    return {
        **result,
        "applied_to_process_env": applied,
    }
