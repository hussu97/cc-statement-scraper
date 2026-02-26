from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
from ccs_platform.api.v1.schemas import BankOut
from ccs_platform.application.banks.capabilities import get_enabled_banks


router = APIRouter(prefix="/banks", tags=["banks"])


@router.get("", response_model=list[BankOut])
def list_banks(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> list[BankOut]:
    rows = get_enabled_banks(db, profile_id=profile.profile_id)
    return [BankOut.model_validate(row) for row in rows]
