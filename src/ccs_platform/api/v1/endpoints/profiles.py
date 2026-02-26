from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ccs_platform.api.deps import get_db
from ccs_platform.api.v1.schemas import ProfileBanksPatchRequest, ProfileOut
from ccs_platform.application.profiles.service import list_profiles_with_banks, replace_profile_banks


router = APIRouter(prefix="/profiles", tags=["profiles"])


@router.get("", response_model=list[ProfileOut])
def list_profiles(db: Session = Depends(get_db)) -> list[ProfileOut]:
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
    db: Session = Depends(get_db),
) -> ProfileOut:
    try:
        profile, banks = replace_profile_banks(db, profile_key=profile_key, bank_codes=payload.bank_codes)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Profile not found: {profile_key}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    db.commit()
    return ProfileOut(
        key=profile.key,
        name=profile.name,
        is_default=profile.is_default,
        banks=banks,
    )
