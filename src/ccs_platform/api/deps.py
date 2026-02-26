from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Header, HTTPException
from sqlalchemy.orm import Session

from ccs_platform.application.profiles.service import get_default_profile, get_profile_by_key
from ccs_platform.db.session import get_db


@dataclass(frozen=True)
class ProfileContext:
    profile_id: int
    profile_key: str
    profile_name: str


def get_profile_context(
    db: Session = Depends(get_db),
    profile_key_header: Annotated[str | None, Header(alias="X-Profile-Key")] = None,
) -> ProfileContext:
    try:
        if profile_key_header and profile_key_header.strip():
            profile = get_profile_by_key(db, profile_key_header)
            if profile is None:
                raise HTTPException(status_code=400, detail=f"Unknown profile key: {profile_key_header}")
        else:
            profile = get_default_profile(db)
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    return ProfileContext(
        profile_id=profile.id,
        profile_key=profile.key,
        profile_name=profile.name,
    )


__all__ = ["ProfileContext", "get_db", "get_profile_context"]
