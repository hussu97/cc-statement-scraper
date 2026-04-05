from __future__ import annotations

from datetime import UTC, datetime
from dataclasses import dataclass
import hashlib
from typing import Annotated

from fastapi import Depends, Header, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.application.auth.service import get_account_by_email, normalize_email
from ccs_platform.application.profiles.service import get_default_profile, get_profile_by_key
from ccs_platform.db import models
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
    is_default: bool = False


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


@dataclass(frozen=True)
class ServiceTokenContext:
    token_id: int
    token_name: str
    scopes: set[str]


def get_authenticated_user_context(request: Request) -> AuthenticatedUserContext:
    settings = request.app.state.settings
    if not settings.login_required():
        request.state.authenticated_email = "local-admin@ccs"
        request.state.default_profile_key = ""
        request.state.actor_role = "admin"
        request.state.actor_subject = "system:local"
        return AuthenticatedUserContext(
            email="local-admin@ccs",
            display_name="Local Admin",
            default_profile_key="",
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
        is_default=bool(profile.is_default),
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


def require_operator_or_service_token(*required_scopes: str):
    """Auth dependency that accepts either a session (operator+) or a Bearer service token.

    If an Authorization header with a Bearer token is present it validates the token and
    required scopes.  Otherwise it falls back to session-based operator authentication.
    Returns an ActorContext so callers can treat both paths uniformly.
    """
    _service_dep = require_service_token(*required_scopes)

    def _dependency(
        request: Request,
        db: Session = Depends(get_db),
        authorization: Annotated[str | None, Header(alias="Authorization")] = None,
    ) -> ActorContext:
        if authorization and authorization.strip().lower().startswith("bearer "):
            svc: ServiceTokenContext = _service_dep(request=request, db=db, authorization=authorization)
            return ActorContext(
                role="service",
                subject=f"service_token:{svc.token_id}",
                request_id=str(getattr(request.state, "request_id", "") or "").strip() or None,
            )
        actor = get_actor_context(request=request)
        settings = request.app.state.settings
        if settings.rbac_enforced() and ROLE_RANK[actor.role] < ROLE_RANK["operator"]:
            raise HTTPException(status_code=403, detail="operator role required")
        return actor

    return _dependency


def get_profile_context_or_service_token(
    *required_scopes: str,
):
    """Returns a ProfileContext from either session or service token auth.

    Service token requests: profile is taken from the token's profile_id.
    Session requests: standard get_profile_context logic (X-Profile-Key header or default).
    """
    _service_dep = require_service_token(*required_scopes)

    def _dependency(
        request: Request,
        db: Session = Depends(get_db),
        authorization: Annotated[str | None, Header(alias="Authorization")] = None,
        profile_key_header: Annotated[str | None, Header(alias="X-Profile-Key")] = None,
    ) -> ProfileContext:
        if authorization and authorization.strip().lower().startswith("bearer "):
            svc: ServiceTokenContext = _service_dep(request=request, db=db, authorization=authorization)
            if not (profile_key_header and profile_key_header.strip()):
                raise HTTPException(status_code=400, detail="X-Profile-Key header is required when using a service token")
            profile = get_profile_by_key(db, profile_key_header.strip())
            if profile is None:
                raise HTTPException(status_code=400, detail=f"Unknown profile key: {profile_key_header}")
            return ProfileContext(
                profile_id=profile.id,
                profile_key=profile.key,
                profile_name=profile.name,
                is_default=bool(profile.is_default),
            )
        # Fall back to session-based profile resolution
        user = get_authenticated_user_context(request)
        return get_profile_context(db=db, user=user, profile_key_header=profile_key_header)

    return _dependency


def _parse_bearer_token(authorization: str | None) -> str:
    value = (authorization or "").strip()
    if not value:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    prefix = "bearer "
    if value.lower().startswith(prefix):
        token = value[len(prefix):].strip()
    else:
        token = value
    if not token:
        raise HTTPException(status_code=401, detail="Invalid bearer token")
    return token


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def require_service_token(*required_scopes: str):
    required = {scope.strip() for scope in required_scopes if scope and scope.strip()}

    def _dependency(
        request: Request,
        db: Session = Depends(get_db),
        authorization: Annotated[str | None, Header(alias="Authorization")] = None,
    ) -> ServiceTokenContext:
        raw = _parse_bearer_token(authorization)
        prefix = raw[:24]
        digest = _token_hash(raw)

        token_row = db.execute(
            select(models.ServiceApiToken)
            .where(
                models.ServiceApiToken.token_prefix == prefix,
                models.ServiceApiToken.token_hash == digest,
                models.ServiceApiToken.is_active.is_(True),
                models.ServiceApiToken.revoked_at.is_(None),
            )
        ).scalar_one_or_none()
        if token_row is None:
            raise HTTPException(status_code=401, detail="Invalid service token")

        if token_row.expires_at is not None:
            expires = token_row.expires_at
            if expires.tzinfo is None:
                expires = expires.replace(tzinfo=UTC)
            if datetime.now(UTC) >= expires:
                raise HTTPException(status_code=401, detail="Service token has expired")

        scopes = {str(item).strip() for item in (token_row.scopes_json or []) if str(item).strip()}
        if required and not required.issubset(scopes):
            raise HTTPException(status_code=403, detail="Service token scope denied")

        token_row.last_used_at = datetime.now(UTC)
        db.commit()

        request.state.actor_role = "service"
        request.state.actor_subject = f"service_token:{token_row.id}"

        return ServiceTokenContext(
            token_id=token_row.id,
            token_name=token_row.name,
            scopes=scopes,
        )

    return _dependency


__all__ = [
    "ActorContext",
    "AuthenticatedUserContext",
    "ProfileContext",
    "ServiceTokenContext",
    "get_actor_context",
    "get_authenticated_user_context",
    "get_db",
    "get_profile_context",
    "get_profile_context_or_service_token",
    "require_operator_or_service_token",
    "require_service_token",
    "require_admin_role",
    "require_operator_role",
    "require_viewer_role",
]
