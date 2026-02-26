from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
from ccs_platform.api.v1.schemas import (
    PaginatedRuntimeSettings,
    RuntimeSettingCreate,
    RuntimeSettingOut,
    RuntimeSettingsSeedRequest,
    RuntimeSettingUpdate,
)
from ccs_platform.core.runtime_settings import (
    apply_runtime_settings_to_process_env,
    decode_runtime_setting_row_value,
    normalize_runtime_key,
    seed_runtime_settings_from_env,
    upsert_runtime_setting,
)
from ccs_platform.core.settings import get_settings
from ccs_platform.db import models


router = APIRouter(prefix="/runtime-settings", tags=["runtime-settings"])


def _to_runtime_setting_out(row: models.RuntimeSetting) -> RuntimeSettingOut:
    settings = get_settings()
    raw_value = row.value or ""
    secret_readback_allowed = settings.secret_value_readback_enabled()
    if row.is_secret and not secret_readback_allowed:
        safe_value = ""
    else:
        safe_value = decode_runtime_setting_row_value(row) if raw_value else ""

    return RuntimeSettingOut(
        id=row.id,
        key=row.key,
        value=safe_value,
        has_value=bool(raw_value),
        bank_code=row.bank_code,
        is_secret=row.is_secret,
        description=row.description,
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


@router.get("", response_model=PaginatedRuntimeSettings)
def list_runtime_settings(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    page: int = 1,
    page_size: int = 100,
    search: str | None = None,
) -> PaginatedRuntimeSettings:
    page = max(page, 1)
    page_size = min(max(page_size, 1), 1000)

    query = select(models.RuntimeSetting).where(models.RuntimeSetting.profile_id == profile.profile_id)
    count_query = select(func.count(models.RuntimeSetting.id)).where(models.RuntimeSetting.profile_id == profile.profile_id)

    if search:
        token = f"%{search.strip().upper()}%"
        predicate = or_(
            func.upper(models.RuntimeSetting.key).like(token),
            func.upper(func.coalesce(models.RuntimeSetting.bank_code, "")).like(token),
            func.upper(func.coalesce(models.RuntimeSetting.description, "")).like(token),
        )
        query = query.where(predicate)
        count_query = count_query.where(predicate)

    total = int(db.execute(count_query).scalar_one())
    rows = db.execute(
        query
        .order_by(models.RuntimeSetting.bank_code.asc(), models.RuntimeSetting.key.asc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).scalars().all()
    return PaginatedRuntimeSettings(
        total=total,
        page=page,
        page_size=page_size,
        items=[_to_runtime_setting_out(row) for row in rows],
    )


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
    return _to_runtime_setting_out(row)


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

    next_value = decode_runtime_setting_row_value(row) if payload.value is None else payload.value
    row = upsert_runtime_setting(
        db,
        profile_id=profile.profile_id,
        key=normalized_key,
        value=next_value,
        bank_code=payload.bank_code,
        is_secret=payload.is_secret,
        description=payload.description,
    )
    db.commit()
    db.refresh(row)
    apply_runtime_settings_to_process_env(db, profile_id=profile.profile_id)
    return _to_runtime_setting_out(row)


@router.post("/seed-from-env")
def seed_runtime_settings(
    payload: RuntimeSettingsSeedRequest,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> dict[str, object]:
    try:
        result = seed_runtime_settings_from_env(
            db,
            profile_id=profile.profile_id,
            overwrite_existing=payload.overwrite_existing,
            blank_values=profile.profile_key != "hussain",
            source_mode=payload.source_mode,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    db.commit()
    applied = apply_runtime_settings_to_process_env(db, profile_id=profile.profile_id)
    return {
        **result,
        "applied_to_process_env": applied,
    }
