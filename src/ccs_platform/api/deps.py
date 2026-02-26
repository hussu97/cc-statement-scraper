from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Header, HTTPException, Request
from sqlalchemy.orm import Session

from ccs_platform.application.auth.service import get_account_by_email, normalize_email
from ccs_platform.application.profiles.service import get_default_profile, get_profile_by_key
from ccs_platform.db.session import get_db


ROLE_RANK = {
    "viewer": 1,
    "operator": 2,
    "admin": 3,
}


@dataclass(frozen=True)
class ProfileContext:
    profile_id: int
    profile_key: str
    profile_name: str


@dataclass(frozen=True)
class AuthenticatedUserContext:
    email: str
    display_name: str
    default_profile_key: str
    role: str


@dataclass(frozen=True)
class ActorContext:
    role: str
    subject: str | None
    request_id: str | None


def get_authenticated_user_context(request: Request) -> AuthenticatedUserContext:
    settings = request.app.state.settings
    if not settings.login_required():
        request.state.authenticated_email = "local-admin@ccs"
        request.state.default_profile_key = "hussain"
        request.state.actor_role = "admin"
        request.state.actor_subject = "system:local"
        return AuthenticatedUserContext(
            email="local-admin@ccs",
            display_name="Local Admin",
            default_profile_key="hussain",
            role="admin",
        )

    session = request.scope.get("session") or {}

    email = normalize_email(
        str(getattr(request.state, "authenticated_email", "") or session.get("email", ""))
    )
    account = get_account_by_email(email) if email else None
    if account is None:
        raise HTTPException(status_code=401, detail="Unauthorized")

    default_profile_key = (
        str(session.get("default_profile_key", "")).strip().lower()
        or account.default_profile_key
    )

    role = str(getattr(request.state, "actor_role", "") or account.role).strip().lower()
    if role not in ROLE_RANK:
        if settings.rbac_enforced():
            raise HTTPException(status_code=403, detail="RBAC role context is required")
        role = "admin"

    request.state.authenticated_email = account.email
    request.state.default_profile_key = default_profile_key
    request.state.actor_role = role
    request.state.actor_subject = f"user:{account.email}"

    return AuthenticatedUserContext(
        email=account.email,
        display_name=account.display_name,
        default_profile_key=default_profile_key,
        role=role,
    )


def get_profile_context(
    db: Session = Depends(get_db),
    user: AuthenticatedUserContext = Depends(get_authenticated_user_context),
    profile_key_header: Annotated[str | None, Header(alias="X-Profile-Key")] = None,
) -> ProfileContext:
    try:
        if profile_key_header and profile_key_header.strip():
            profile = get_profile_by_key(db, profile_key_header)
            if profile is None:
                raise HTTPException(status_code=400, detail=f"Unknown profile key: {profile_key_header}")
        else:
            profile = get_profile_by_key(db, user.default_profile_key) or get_default_profile(db)
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    return ProfileContext(
        profile_id=profile.id,
        profile_key=profile.key,
        profile_name=profile.name,
    )


def get_actor_context(request: Request) -> ActorContext:
    user = get_authenticated_user_context(request)
    role = str(getattr(request.state, "actor_role", "") or "").strip().lower()
    if role not in ROLE_RANK:
        role = user.role
    return ActorContext(
        role=role,
        subject=(
            str(getattr(request.state, "actor_subject", "") or "").strip()
            or f"user:{user.email}"
        ),
        request_id=str(getattr(request.state, "request_id", "") or "").strip() or None,
    )


def _require_role(minimum_role: str):
    required = minimum_role.strip().lower()
    if required not in ROLE_RANK:
        raise RuntimeError(f"Unsupported RBAC role: {minimum_role}")

    def _dependency(
        request: Request,
        actor: ActorContext = Depends(get_actor_context),
    ) -> ActorContext:
        settings = request.app.state.settings
        if settings.rbac_enforced() and ROLE_RANK[actor.role] < ROLE_RANK[required]:
            raise HTTPException(status_code=403, detail=f"{required} role required")
        return actor

    return _dependency


require_viewer_role = _require_role("viewer")
require_operator_role = _require_role("operator")
require_admin_role = _require_role("admin")


__all__ = [
    "ActorContext",
    "AuthenticatedUserContext",
    "ProfileContext",
    "get_actor_context",
    "get_authenticated_user_context",
    "get_db",
    "get_profile_context",
    "require_admin_role",
    "require_operator_role",
    "require_viewer_role",
]
