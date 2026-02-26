from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

from ccs_platform.api.audit import append_audit_event
from ccs_platform.api.deps import (
    ActorContext,
    get_db,
    require_admin_role,
    require_viewer_role,
)
from ccs_platform.api.v1.schemas import ProfileBanksPatchRequest, ProfileOut
from ccs_platform.application.profiles.service import list_profiles_with_banks, replace_profile_banks


router = APIRouter(prefix="/profiles", tags=["profiles"])


@router.get("", response_model=list[ProfileOut])
def list_profiles(
    db: Session = Depends(get_db),
    _actor: ActorContext = Depends(require_viewer_role),
) -> list[ProfileOut]:
    rows = list_profiles_with_banks(db)
    return [
        ProfileOut(
            key=profile.key,
            name=profile.name,
            is_default=profile.is_default,
            banks=banks,
        )
        for profile, banks in rows
    ]


@router.patch("/{profile_key}/banks", response_model=ProfileOut)
def patch_profile_banks(
    profile_key: str,
    payload: ProfileBanksPatchRequest,
    request: Request,
    db: Session = Depends(get_db),
    actor: ActorContext = Depends(require_admin_role),
) -> ProfileOut:
    before_banks_by_key = {
        profile.key: banks
        for profile, banks in list_profiles_with_banks(db)
    }

    try:
        profile, banks = replace_profile_banks(db, profile_key=profile_key, bank_codes=payload.bank_codes)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Profile not found: {profile_key}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    append_audit_event(
        db,
        profile_id=profile.id,
        event_type="profile_banks_updated",
        entity_type="profile",
        entity_id=profile.key,
        payload_json={
            "before_banks": before_banks_by_key.get(profile.key, []),
            "after_banks": banks,
        },
        request=request,
    )
    db.commit()
    return ProfileOut(
        key=profile.key,
        name=profile.name,
        is_default=profile.is_default,
        banks=banks,
    )
