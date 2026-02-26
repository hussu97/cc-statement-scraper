from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from ccs_platform.application.profiles.service import DEFAULT_PROFILE_KEY, list_profiles_with_banks
from ccs_platform.core.runtime_settings import apply_runtime_settings_to_process_env, seed_runtime_settings_from_env


def seed_runtime_settings(db: Session) -> dict[str, Any]:
    profiles = [profile for profile, _ in list_profiles_with_banks(db)]
    if not profiles:
        return {"profiles": [], "applied_to_process_env": 0}

    result_by_profile: dict[str, dict[str, Any]] = {}
    default_profile_id: int | None = None

    for profile in profiles:
        blank_values = profile.key != DEFAULT_PROFILE_KEY
        profile_result = seed_runtime_settings_from_env(
            db,
            profile_id=profile.id,
            blank_values=blank_values,
        )
        result_by_profile[profile.key] = profile_result
        if profile.key == DEFAULT_PROFILE_KEY:
            default_profile_id = profile.id

    db.flush()
    if default_profile_id is None:
        default_profile_id = profiles[0].id
    applied = apply_runtime_settings_to_process_env(db, profile_id=default_profile_id)
    return {"profiles": result_by_profile, "applied_to_process_env": applied}
