from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from sqlalchemy.orm import Session

from ccs_platform.api.deps import AuthenticatedUserContext, get_authenticated_user_context
from ccs_platform.api.v1.schemas import AuthUserOut, LoginRequest, LoginResponse
from ccs_platform.application.auth.service import authenticate_credentials
from ccs_platform.application.profiles.service import get_default_profile, get_profile_by_key
from ccs_platform.db.session import get_db


router = APIRouter(prefix="/auth", tags=["auth"])


def _resolve_default_profile_key(db: Session, preferred_profile_key: str) -> str:
    preferred = get_profile_by_key(db, preferred_profile_key)
    if preferred is not None:
        return preferred.key
    return get_default_profile(db).key


def _to_auth_user(
    *,
    email: str,
    display_name: str,
    default_profile_key: str,
    role: str,
) -> AuthUserOut:
    return AuthUserOut(
        email=email,
        display_name=display_name,
        default_profile_key=default_profile_key,
        role=role,
    )


@router.post("/login", response_model=LoginResponse)
def login(
    payload: LoginRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> LoginResponse:
    account = authenticate_credentials(email=payload.email, password=payload.password)
    if account is None:
        raise HTTPException(status_code=401, detail="Invalid email or password")

    default_profile_key = _resolve_default_profile_key(db, account.default_profile_key)
    request.session.clear()
    request.session["email"] = account.email
    request.session["role"] = account.role
    request.session["default_profile_key"] = default_profile_key

    request.state.authenticated_email = account.email
    request.state.actor_role = account.role
    request.state.actor_subject = f"user:{account.email}"

    return LoginResponse(
        user=_to_auth_user(
            email=account.email,
            display_name=account.display_name,
            default_profile_key=default_profile_key,
            role=account.role,
        )
    )


@router.get("/me", response_model=LoginResponse)
def me(
    db: Session = Depends(get_db),
    user: AuthenticatedUserContext = Depends(get_authenticated_user_context),
) -> LoginResponse:
    default_profile_key = _resolve_default_profile_key(db, user.default_profile_key)
    return LoginResponse(
        user=_to_auth_user(
            email=user.email,
            display_name=user.display_name,
            default_profile_key=default_profile_key,
            role=user.role,
        )
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(request: Request) -> Response:
    request.session.clear()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
