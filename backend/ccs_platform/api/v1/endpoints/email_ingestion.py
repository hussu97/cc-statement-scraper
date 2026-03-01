from __future__ import annotations

from datetime import UTC, datetime, timedelta
import hashlib
import json
from pathlib import Path
import secrets
from typing import Any
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request

from fastapi import APIRouter, Depends, File, Form, HTTPException, Path as PathParam, Query, Request, UploadFile
from sqlalchemy import and_, func, or_, select
from sqlalchemy.orm import Session

from ccs_platform.api.audit import append_audit_event
from ccs_platform.api.deps import (
    ActorContext,
    ProfileContext,
    ServiceTokenContext,
    get_db,
    get_profile_context,
    require_admin_role,
    require_service_token,
)
from ccs_platform.api.v1.schemas import (
    EmailBankRouteOut,
    EmailBankRouteUpsert,
    EmailIngestionUploadResponse,
    EmailMailboxCreate,
    EmailMailboxOut,
    EmailMailboxPatch,
    EmailMailboxSyncStatePatch,
    OAuthAccessTokenOut,
    OAuthAccessTokenRequest,
    OAuthCodeExchangeOut,
    OAuthCodeExchangeRequest,
    OAuthConfigOut,
    PaginatedEmailIngestionEvents,
    PaginatedEmailMailboxes,
    PaginatedEmailRoutes,
    ServiceApiTokenCreate,
    ServiceApiTokenCreated,
    ServiceApiTokenOut,
)
from ccs_platform.application.jobs.service import create_or_get_job
from ccs_platform.core.runtime_settings import decode_runtime_setting_row_value, normalize_runtime_key
from ccs_platform.core.settings import get_settings
from ccs_platform.db import models
from ccs_platform.db.models.enums import EmailIngestionStatus, EmailProvider, JobType


router = APIRouter(prefix="/email-ingestion", tags=["email-ingestion"])

SERVICE_SCOPE_READ = "email_ingestion:read"
SERVICE_SCOPE_WRITE = "email_ingestion:write"
SERVICE_SCOPE_UPLOAD = "email_ingestion:upload"
DEFAULT_SERVICE_SCOPES = [SERVICE_SCOPE_READ, SERVICE_SCOPE_WRITE, SERVICE_SCOPE_UPLOAD]

TOKEN_ENDPOINT_BY_PROVIDER = {
    EmailProvider.MICROSOFT: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
    EmailProvider.GMAIL: "https://oauth2.googleapis.com/token",
}
CLIENT_ID_KEY_BY_PROVIDER = {
    EmailProvider.MICROSOFT: "EMAIL_MS_CLIENT_ID",
    EmailProvider.GMAIL: "EMAIL_GMAIL_CLIENT_ID",
}
CLIENT_SECRET_KEY_BY_PROVIDER = {
    EmailProvider.MICROSOFT: "EMAIL_MS_CLIENT_SECRET",
    EmailProvider.GMAIL: "EMAIL_GMAIL_CLIENT_SECRET",
}
REFRESH_TOKEN_KEY_TEMPLATE_BY_PROVIDER = {
    EmailProvider.MICROSOFT: "EMAIL_MS_REFRESH_TOKEN_MAILBOX_{mailbox_id}",
    EmailProvider.GMAIL: "EMAIL_GMAIL_REFRESH_TOKEN_MAILBOX_{mailbox_id}",
}

# Auth URL templates for the in-UI OAuth flow (code exchange uses /consumers/ endpoint).
# redirect_uri is injected at request time from CCS_PLATFORM_EMAIL_OAUTH_REDIRECT_URI.
_MS_AUTH_URL_TEMPLATE = (
    "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize"
    "?client_id={client_id}"
    "&response_type=code"
    "&redirect_uri={redirect_uri}"
    "&scope=Mail.Read%20offline_access"
    "&response_mode=query"
)
_GMAIL_AUTH_URL_TEMPLATE = (
    "https://accounts.google.com/o/oauth2/v2/auth"
    "?client_id={client_id}"
    "&redirect_uri={redirect_uri}"
    "&response_type=code"
    "&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.readonly"
    "&access_type=offline"
    "&prompt=consent"
)
_EXCHANGE_TOKEN_ENDPOINT_BY_PROVIDER = {
    EmailProvider.MICROSOFT: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
    EmailProvider.GMAIL: "https://oauth2.googleapis.com/token",
}


def _ensure_enabled(request: Request) -> None:
    if not bool(request.app.state.settings.email_ingestion_enabled):
        raise HTTPException(status_code=404, detail="Email ingestion is disabled")


def _normalize_list(values: list[str] | None) -> list[str] | None:
    if values is None:
        return None
    normalized = [str(item).strip() for item in values if str(item).strip()]
    return normalized or None


_SETTINGS_FALLBACK_MAP: dict[str, str] = {
    "EMAIL_MS_CLIENT_ID": "email_ms_client_id",
    "EMAIL_MS_CLIENT_SECRET": "email_ms_client_secret",
    "EMAIL_GMAIL_CLIENT_ID": "email_gmail_client_id",
    "EMAIL_GMAIL_CLIENT_SECRET": "email_gmail_client_secret",
}


def _runtime_setting_value(db: Session, *, profile_id: int, key: str) -> str:
    normalized_key = normalize_runtime_key(key)
    row = db.execute(
        select(models.RuntimeSetting).where(
            models.RuntimeSetting.profile_id == profile_id,
            models.RuntimeSetting.key == normalized_key,
        )
    ).scalar_one_or_none()
    if row is not None:
        value = decode_runtime_setting_row_value(row).strip()
        if value:
            return value

    # Fall back to Pydantic settings (populated from CCS_PLATFORM_* env vars).
    settings_attr = _SETTINGS_FALLBACK_MAP.get(normalized_key)
    if settings_attr:
        fallback = (getattr(get_settings(), settings_attr, None) or "").strip()
        if fallback:
            return fallback

    if row is None:
        raise HTTPException(status_code=400, detail=f"Missing runtime setting: {normalized_key}")
    raise HTTPException(status_code=400, detail=f"Runtime setting is empty: {normalized_key}")


def _mailbox_to_out(row: models.EmailMailbox) -> EmailMailboxOut:
    return EmailMailboxOut.model_validate(row)


def _route_to_out(row: models.EmailBankRoute, *, mailbox: models.EmailMailbox) -> EmailBankRouteOut:
    return EmailBankRouteOut(
        id=row.id,
        profile_id=row.profile_id,
        bank_code=row.bank_code,
        mailbox_id=row.mailbox_id,
        provider=mailbox.provider,
        mailbox_email=mailbox.mailbox_email,
        sender_allowlist_json=row.sender_allowlist_json,
        subject_keywords_json=row.subject_keywords_json,
        attachment_filename_regex=row.attachment_filename_regex,
        gmail_label_filter_json=row.gmail_label_filter_json,
        is_active=row.is_active,
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


def _service_token_to_out(row: models.ServiceApiToken) -> ServiceApiTokenOut:
    return ServiceApiTokenOut.model_validate(row)


def _list_mailboxes_for_profile(
    *,
    db: Session,
    profile_id: int | None,
    page: int,
    page_size: int,
    provider: EmailProvider | None,
    active: bool | None,
) -> PaginatedEmailMailboxes:
    query = select(models.EmailMailbox)
    count_query = select(func.count(models.EmailMailbox.id))
    if profile_id is not None:
        query = query.where(models.EmailMailbox.profile_id == profile_id)
        count_query = count_query.where(models.EmailMailbox.profile_id == profile_id)

    if provider is not None:
        query = query.where(models.EmailMailbox.provider == provider)
        count_query = count_query.where(models.EmailMailbox.provider == provider)
    if active is not None:
        query = query.where(models.EmailMailbox.is_active.is_(active))
        count_query = count_query.where(models.EmailMailbox.is_active.is_(active))

    total = int(db.execute(count_query).scalar_one())
    rows = db.execute(
        query.order_by(models.EmailMailbox.updated_at.desc()).offset((page - 1) * page_size).limit(page_size)
    ).scalars().all()
    return PaginatedEmailMailboxes(
        items=[_mailbox_to_out(row) for row in rows],
        total=total,
        page=page,
        page_size=page_size,
    )


def _list_routes_for_profile(
    *,
    db: Session,
    profile_id: int | None,
    page: int,
    page_size: int,
    provider: EmailProvider | None,
    active: bool | None,
) -> PaginatedEmailRoutes:
    query = (
        select(models.EmailBankRoute, models.EmailMailbox)
        .join(models.EmailMailbox, models.EmailMailbox.id == models.EmailBankRoute.mailbox_id)
    )
    count_query = (
        select(func.count(models.EmailBankRoute.id))
        .join(models.EmailMailbox, models.EmailMailbox.id == models.EmailBankRoute.mailbox_id)
    )
    if profile_id is not None:
        query = query.where(models.EmailBankRoute.profile_id == profile_id)
        count_query = count_query.where(models.EmailBankRoute.profile_id == profile_id)
    if provider is not None:
        query = query.where(models.EmailMailbox.provider == provider)
        count_query = count_query.where(models.EmailMailbox.provider == provider)
    if active is not None:
        predicate = and_(
            models.EmailBankRoute.is_active.is_(active),
            models.EmailMailbox.is_active.is_(active),
        )
        query = query.where(predicate)
        count_query = count_query.where(predicate)

    total = int(db.execute(count_query).scalar_one())
    rows = db.execute(
        query
        .order_by(models.EmailBankRoute.bank_code.asc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).all()
    return PaginatedEmailRoutes(
        items=[_route_to_out(route, mailbox=mailbox) for route, mailbox in rows],
        total=total,
        page=page,
        page_size=page_size,
    )


def _provider_access_token(
    *,
    provider: EmailProvider,
    client_id: str,
    client_secret: str,
    refresh_token: str,
) -> tuple[str, str, int]:
    payload: dict[str, str] = {
        "grant_type": "refresh_token",
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
    }
    if provider == EmailProvider.MICROSOFT:
        payload["scope"] = "offline_access https://graph.microsoft.com/Mail.Read"

    encoded = urllib_parse.urlencode(payload).encode("utf-8")
    req = urllib_request.Request(
        TOKEN_ENDPOINT_BY_PROVIDER[provider],
        data=encoded,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib_request.urlopen(req, timeout=20) as resp:  # nosec B310
            raw = resp.read().decode("utf-8")
    except urllib_error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore")
        raise HTTPException(
            status_code=502,
            detail=f"Provider token refresh failed ({provider.value}): HTTP {exc.code} {body[:300]}",
        ) from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Provider token refresh failed ({provider.value})") from exc

    try:
        doc = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Invalid token response from {provider.value}") from exc

    access_token = str(doc.get("access_token") or "").strip()
    token_type = str(doc.get("token_type") or "Bearer").strip() or "Bearer"
    expires_in = int(doc.get("expires_in") or 3600)
    if not access_token:
        detail = str(doc.get("error_description") or doc.get("error") or "missing access_token")
        raise HTTPException(status_code=502, detail=f"Token refresh failed ({provider.value}): {detail}")
    return access_token, token_type, expires_in


@router.get("/mailboxes", response_model=PaginatedEmailMailboxes, dependencies=[Depends(_ensure_enabled)])
def list_mailboxes(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    _actor: ActorContext = Depends(require_admin_role),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=1000),
    provider: EmailProvider | None = None,
    active: bool | None = None,
) -> PaginatedEmailMailboxes:
    return _list_mailboxes_for_profile(
        db=db,
        profile_id=profile.profile_id,
        page=page,
        page_size=page_size,
        provider=provider,
        active=active,
    )


@router.get(
    "/automation/mailboxes",
    response_model=PaginatedEmailMailboxes,
    dependencies=[Depends(_ensure_enabled)],
)
def list_mailboxes_for_automation(
    db: Session = Depends(get_db),
    _token: ServiceTokenContext = Depends(require_service_token(SERVICE_SCOPE_READ)),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=1000),
    provider: EmailProvider | None = None,
    active: bool | None = None,
) -> PaginatedEmailMailboxes:
    return _list_mailboxes_for_profile(
        db=db,
        profile_id=None,
        page=page,
        page_size=page_size,
        provider=provider,
        active=active,
    )


@router.post("/mailboxes", response_model=EmailMailboxOut, dependencies=[Depends(_ensure_enabled)])
def create_mailbox(
    payload: EmailMailboxCreate,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    _actor: ActorContext = Depends(require_admin_role),
) -> EmailMailboxOut:
    mailbox = models.EmailMailbox(
        profile_id=profile.profile_id,
        provider=payload.provider,
        mailbox_email=payload.mailbox_email.strip().lower(),
        display_name=(payload.display_name or "").strip() or None,
        is_active=payload.is_active,
    )
    db.add(mailbox)
    db.flush()
    append_audit_event(
        db,
        profile_id=profile.profile_id,
        event_type="email_mailbox_created",
        entity_type="email_mailbox",
        entity_id=str(mailbox.id),
        payload_json={"provider": mailbox.provider.value, "mailbox_email": mailbox.mailbox_email},
        request=request,
    )
    db.commit()
    db.refresh(mailbox)
    return _mailbox_to_out(mailbox)


@router.patch("/mailboxes/{mailbox_id}", response_model=EmailMailboxOut, dependencies=[Depends(_ensure_enabled)])
def patch_mailbox(
    mailbox_id: int,
    payload: EmailMailboxPatch,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    _actor: ActorContext = Depends(require_admin_role),
) -> EmailMailboxOut:
    mailbox = db.execute(
        select(models.EmailMailbox).where(
            models.EmailMailbox.id == mailbox_id,
            models.EmailMailbox.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if mailbox is None:
        raise HTTPException(status_code=404, detail="Mailbox not found")

    if payload.mailbox_email is not None:
        mailbox.mailbox_email = payload.mailbox_email.strip().lower()
    if payload.display_name is not None:
        mailbox.display_name = payload.display_name.strip() or None
    if payload.is_active is not None:
        mailbox.is_active = payload.is_active

    append_audit_event(
        db,
        profile_id=profile.profile_id,
        event_type="email_mailbox_updated",
        entity_type="email_mailbox",
        entity_id=str(mailbox.id),
        payload_json={"is_active": mailbox.is_active, "mailbox_email": mailbox.mailbox_email},
        request=request,
    )
    db.commit()
    db.refresh(mailbox)
    return _mailbox_to_out(mailbox)


@router.get("/routes", response_model=PaginatedEmailRoutes, dependencies=[Depends(_ensure_enabled)])
def list_routes(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    _actor: ActorContext = Depends(require_admin_role),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=1000),
    provider: EmailProvider | None = None,
    active: bool | None = None,
) -> PaginatedEmailRoutes:
    return _list_routes_for_profile(
        db=db,
        profile_id=profile.profile_id,
        page=page,
        page_size=page_size,
        provider=provider,
        active=active,
    )


@router.get(
    "/automation/routes",
    response_model=PaginatedEmailRoutes,
    dependencies=[Depends(_ensure_enabled)],
)
def list_routes_for_automation(
    db: Session = Depends(get_db),
    _token: ServiceTokenContext = Depends(require_service_token(SERVICE_SCOPE_READ)),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=1000),
    provider: EmailProvider | None = None,
    active: bool | None = None,
) -> PaginatedEmailRoutes:
    return _list_routes_for_profile(
        db=db,
        profile_id=None,
        page=page,
        page_size=page_size,
        provider=provider,
        active=active,
    )


@router.put("/routes/{bank_code}", response_model=EmailBankRouteOut, dependencies=[Depends(_ensure_enabled)])
def upsert_route(
    bank_code: str = PathParam(..., min_length=2, max_length=16),
    payload: EmailBankRouteUpsert = ...,
    request: Request = ...,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    _actor: ActorContext = Depends(require_admin_role),
) -> EmailBankRouteOut:
    normalized_bank = bank_code.strip().upper()
    bank_enabled = db.execute(
        select(models.ProfileBank).where(
            models.ProfileBank.profile_id == profile.profile_id,
            models.ProfileBank.bank_code == normalized_bank,
        )
    ).scalar_one_or_none()
    if bank_enabled is None:
        raise HTTPException(status_code=400, detail=f"Bank {normalized_bank} is not enabled for this profile")

    mailbox = db.execute(
        select(models.EmailMailbox).where(
            models.EmailMailbox.id == payload.mailbox_id,
            models.EmailMailbox.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if mailbox is None:
        raise HTTPException(status_code=400, detail="Mailbox not found for this profile")

    route = db.execute(
        select(models.EmailBankRoute).where(
            models.EmailBankRoute.profile_id == profile.profile_id,
            models.EmailBankRoute.bank_code == normalized_bank,
        )
    ).scalar_one_or_none()

    if route is None:
        route = models.EmailBankRoute(
            profile_id=profile.profile_id,
            bank_code=normalized_bank,
            mailbox_id=payload.mailbox_id,
            sender_allowlist_json=_normalize_list(payload.sender_allowlist_json),
            subject_keywords_json=_normalize_list(payload.subject_keywords_json),
            attachment_filename_regex=(payload.attachment_filename_regex or "").strip() or None,
            gmail_label_filter_json=payload.gmail_label_filter_json or None,
            is_active=payload.is_active,
        )
        db.add(route)
    else:
        route.mailbox_id = payload.mailbox_id
        route.sender_allowlist_json = _normalize_list(payload.sender_allowlist_json)
        route.subject_keywords_json = _normalize_list(payload.subject_keywords_json)
        route.attachment_filename_regex = (payload.attachment_filename_regex or "").strip() or None
        route.gmail_label_filter_json = payload.gmail_label_filter_json or None
        route.is_active = payload.is_active

    db.flush()
    append_audit_event(
        db,
        profile_id=profile.profile_id,
        event_type="email_bank_route_upserted",
        entity_type="email_bank_route",
        entity_id=str(route.id),
        payload_json={"bank_code": normalized_bank, "mailbox_id": route.mailbox_id, "is_active": route.is_active},
        request=request,
    )
    db.commit()
    db.refresh(route)
    mailbox = db.get(models.EmailMailbox, route.mailbox_id)
    if mailbox is None:
        raise HTTPException(status_code=500, detail="Mailbox reference is invalid")
    return _route_to_out(route, mailbox=mailbox)


@router.get("/events", response_model=PaginatedEmailIngestionEvents, dependencies=[Depends(_ensure_enabled)])
def list_events(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    _actor: ActorContext = Depends(require_admin_role),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=1000),
    bank_code: str | None = None,
    provider: EmailProvider | None = None,
    status: EmailIngestionStatus | None = None,
    search: str | None = None,
    created_from: datetime | None = None,
    created_to: datetime | None = None,
) -> PaginatedEmailIngestionEvents:
    query = select(models.EmailIngestionEvent).where(models.EmailIngestionEvent.profile_id == profile.profile_id)
    count_query = select(func.count(models.EmailIngestionEvent.id)).where(
        models.EmailIngestionEvent.profile_id == profile.profile_id
    )
    if bank_code:
        normalized = bank_code.strip().upper()
        query = query.where(models.EmailIngestionEvent.bank_code == normalized)
        count_query = count_query.where(models.EmailIngestionEvent.bank_code == normalized)
    if provider is not None:
        query = query.where(models.EmailIngestionEvent.provider == provider)
        count_query = count_query.where(models.EmailIngestionEvent.provider == provider)
    if status is not None:
        query = query.where(models.EmailIngestionEvent.status == status)
        count_query = count_query.where(models.EmailIngestionEvent.status == status)
    if search:
        token = f"%{search.strip().lower()}%"
        predicate = or_(
            func.lower(models.EmailIngestionEvent.attachment_filename).like(token),
            func.lower(models.EmailIngestionEvent.provider_message_id).like(token),
            func.lower(func.coalesce(models.EmailIngestionEvent.internet_message_id, "")).like(token),
        )
        query = query.where(predicate)
        count_query = count_query.where(predicate)
    if created_from is not None:
        query = query.where(models.EmailIngestionEvent.created_at >= created_from)
        count_query = count_query.where(models.EmailIngestionEvent.created_at >= created_from)
    if created_to is not None:
        query = query.where(models.EmailIngestionEvent.created_at <= created_to)
        count_query = count_query.where(models.EmailIngestionEvent.created_at <= created_to)

    total = int(db.execute(count_query).scalar_one())
    rows = db.execute(
        query.order_by(models.EmailIngestionEvent.created_at.desc()).offset((page - 1) * page_size).limit(page_size)
    ).scalars().all()
    return PaginatedEmailIngestionEvents(
        items=[item for item in rows],
        total=total,
        page=page,
        page_size=page_size,
    )


@router.get("/service-tokens", response_model=list[ServiceApiTokenOut], dependencies=[Depends(_ensure_enabled)])
def list_service_tokens(
    db: Session = Depends(get_db),
    _actor: ActorContext = Depends(require_admin_role),
) -> list[ServiceApiTokenOut]:
    rows = db.execute(
        select(models.ServiceApiToken)
        .order_by(models.ServiceApiToken.created_at.desc())
    ).scalars().all()
    return [_service_token_to_out(row) for row in rows]


@router.post("/service-tokens", response_model=ServiceApiTokenCreated, dependencies=[Depends(_ensure_enabled)])
def create_service_token(
    payload: ServiceApiTokenCreate,
    db: Session = Depends(get_db),
    _actor: ActorContext = Depends(require_admin_role),
) -> ServiceApiTokenCreated:
    scopes = [scope.strip() for scope in payload.scopes if scope.strip()]
    if not scopes:
        raise HTTPException(status_code=400, detail="At least one scope is required")

    token_plain = secrets.token_urlsafe(48)
    token_prefix = token_plain[:24]
    token_hash = hashlib.sha256(token_plain.encode("utf-8")).hexdigest()
    row = models.ServiceApiToken(
        name=payload.name.strip(),
        token_prefix=token_prefix,
        token_hash=token_hash,
        scopes_json=scopes,
        is_active=True,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return ServiceApiTokenCreated(token=token_plain, item=_service_token_to_out(row))


@router.post(
    "/service-tokens/{token_id}/revoke",
    response_model=ServiceApiTokenOut,
    dependencies=[Depends(_ensure_enabled)],
)
def revoke_service_token(
    token_id: int,
    db: Session = Depends(get_db),
    _actor: ActorContext = Depends(require_admin_role),
) -> ServiceApiTokenOut:
    row = db.execute(
        select(models.ServiceApiToken).where(
            models.ServiceApiToken.id == token_id,
        )
    ).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="Service token not found")
    row.is_active = False
    row.revoked_at = datetime.now(UTC)
    db.commit()
    db.refresh(row)
    return _service_token_to_out(row)


@router.post(
    "/oauth/{provider}/access-token",
    response_model=OAuthAccessTokenOut,
    dependencies=[Depends(_ensure_enabled)],
)
def provider_access_token(
    provider: EmailProvider,
    payload: OAuthAccessTokenRequest,
    db: Session = Depends(get_db),
    _token: ServiceTokenContext = Depends(require_service_token(SERVICE_SCOPE_READ)),
) -> OAuthAccessTokenOut:
    mailbox = db.execute(
        select(models.EmailMailbox).where(
            models.EmailMailbox.id == payload.mailbox_id,
            models.EmailMailbox.provider == provider,
            models.EmailMailbox.is_active.is_(True),
        )
    ).scalar_one_or_none()
    if mailbox is None:
        raise HTTPException(status_code=404, detail="Mailbox not found")

    profile_id = mailbox.profile_id
    client_id = _runtime_setting_value(db, profile_id=profile_id, key=CLIENT_ID_KEY_BY_PROVIDER[provider])
    client_secret = _runtime_setting_value(
        db,
        profile_id=profile_id,
        key=CLIENT_SECRET_KEY_BY_PROVIDER[provider],
    )
    refresh_key = REFRESH_TOKEN_KEY_TEMPLATE_BY_PROVIDER[provider].format(mailbox_id=mailbox.id)
    refresh_token = _runtime_setting_value(db, profile_id=profile_id, key=refresh_key)

    access_token, token_type, expires_in = _provider_access_token(
        provider=provider,
        client_id=client_id,
        client_secret=client_secret,
        refresh_token=refresh_token,
    )
    expires_at = datetime.now(UTC) + timedelta(seconds=max(60, expires_in))
    return OAuthAccessTokenOut(
        provider=provider,
        access_token=access_token,
        token_type=token_type,
        expires_at=expires_at,
    )


@router.get(
    "/oauth/config",
    response_model=list[OAuthConfigOut],
    dependencies=[Depends(_ensure_enabled)],
)
def oauth_config(
    _actor: ActorContext = Depends(require_admin_role),
) -> list[OAuthConfigOut]:
    """Return auth URLs and configuration status for each OAuth provider."""
    settings = get_settings()
    ms_client_id = (settings.email_ms_client_id or "").strip()
    ms_client_secret = (settings.email_ms_client_secret or "").strip()
    gmail_client_id = (settings.email_gmail_client_id or "").strip()
    gmail_client_secret = (settings.email_gmail_client_secret or "").strip()

    ms_configured = bool(ms_client_id and ms_client_secret)
    gmail_configured = bool(gmail_client_id and gmail_client_secret)

    redirect_uri = urllib_parse.quote(settings.email_oauth_redirect_uri, safe="")
    return [
        OAuthConfigOut(
            provider=EmailProvider.MICROSOFT,
            auth_url=_MS_AUTH_URL_TEMPLATE.format(client_id=ms_client_id, redirect_uri=redirect_uri) if ms_client_id else None,
            configured=ms_configured,
        ),
        OAuthConfigOut(
            provider=EmailProvider.GMAIL,
            auth_url=_GMAIL_AUTH_URL_TEMPLATE.format(client_id=gmail_client_id, redirect_uri=redirect_uri) if gmail_client_id else None,
            configured=gmail_configured,
        ),
    ]


@router.post(
    "/oauth/exchange-code",
    response_model=OAuthCodeExchangeOut,
    dependencies=[Depends(_ensure_enabled)],
)
def oauth_exchange_code(
    payload: OAuthCodeExchangeRequest,
    _actor: ActorContext = Depends(require_admin_role),
) -> OAuthCodeExchangeOut:
    """Exchange an OAuth authorisation code for a refresh token (server-side)."""
    settings = get_settings()
    provider = payload.provider

    if provider == EmailProvider.MICROSOFT:
        client_id = (settings.email_ms_client_id or "").strip()
        client_secret = (settings.email_ms_client_secret or "").strip()
    else:
        client_id = (settings.email_gmail_client_id or "").strip()
        client_secret = (settings.email_gmail_client_secret or "").strip()

    if not client_id or not client_secret:
        raise HTTPException(
            status_code=400,
            detail=f"OAuth credentials for {provider.value} are not configured. Set the env vars and restart.",
        )

    post_data: dict[str, str] = {
        "grant_type": "authorization_code",
        "client_id": client_id,
        "client_secret": client_secret,
        "code": payload.code.strip(),
        "redirect_uri": settings.email_oauth_redirect_uri,
    }
    encoded = urllib_parse.urlencode(post_data).encode("utf-8")
    req = urllib_request.Request(
        _EXCHANGE_TOKEN_ENDPOINT_BY_PROVIDER[provider],
        data=encoded,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib_request.urlopen(req, timeout=20) as resp:  # nosec B310
            raw = resp.read().decode("utf-8")
    except urllib_error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore")
        raise HTTPException(
            status_code=502,
            detail=f"Token exchange failed ({provider.value}): HTTP {exc.code} {body[:300]}",
        ) from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Token exchange failed ({provider.value})") from exc

    try:
        doc = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Invalid token response from {provider.value}") from exc

    refresh_token = str(doc.get("refresh_token") or "").strip()
    if not refresh_token:
        detail = str(doc.get("error_description") or doc.get("error") or "missing refresh_token")
        raise HTTPException(status_code=502, detail=f"Token exchange failed ({provider.value}): {detail}")

    return OAuthCodeExchangeOut(provider=provider, refresh_token=refresh_token)


@router.post(
    "/mailboxes/{mailbox_id}/sync-state",
    response_model=EmailMailboxOut,
    dependencies=[Depends(_ensure_enabled)],
)
def patch_mailbox_sync_state(
    mailbox_id: int,
    payload: EmailMailboxSyncStatePatch,
    db: Session = Depends(get_db),
    _token: ServiceTokenContext = Depends(require_service_token(SERVICE_SCOPE_WRITE)),
) -> EmailMailboxOut:
    mailbox = db.execute(
        select(models.EmailMailbox).where(
            models.EmailMailbox.id == mailbox_id,
        )
    ).scalar_one_or_none()
    if mailbox is None:
        raise HTTPException(status_code=404, detail="Mailbox not found")

    if payload.sync_state_json is not None:
        mailbox.sync_state_json = payload.sync_state_json
    if payload.watch_expiration_at is not None:
        mailbox.watch_expiration_at = payload.watch_expiration_at
    if payload.last_sync_at is not None:
        mailbox.last_sync_at = payload.last_sync_at
    if payload.last_error_at is not None:
        mailbox.last_error_at = payload.last_error_at
    if payload.last_error_message is not None:
        mailbox.last_error_message = payload.last_error_message

    db.commit()
    db.refresh(mailbox)
    return _mailbox_to_out(mailbox)


@router.post("/upload", response_model=EmailIngestionUploadResponse, dependencies=[Depends(_ensure_enabled)])
async def ingestion_upload(
    request: Request,
    file: UploadFile = File(...),
    route_id: int = Form(...),
    provider_message_id: str = Form(...),
    provider_attachment_id: str = Form(...),
    internet_message_id: str | None = Form(None),
    provider_received_at: datetime | None = Form(None),
    metadata_json: str | None = Form(None),
    db: Session = Depends(get_db),
    _token: ServiceTokenContext = Depends(require_service_token(SERVICE_SCOPE_UPLOAD)),
) -> EmailIngestionUploadResponse:
    route = db.execute(
        select(models.EmailBankRoute).where(
            models.EmailBankRoute.id == route_id,
            models.EmailBankRoute.is_active.is_(True),
        )
    ).scalar_one_or_none()
    if route is None:
        raise HTTPException(status_code=404, detail="Route not found")

    profile_id = route.profile_id
    profile = db.get(models.Profile, profile_id)
    profile_key = profile.key if profile is not None else ""

    mailbox = db.get(models.EmailMailbox, route.mailbox_id)
    if mailbox is None or not mailbox.is_active:
        raise HTTPException(status_code=400, detail="Route mailbox is inactive or missing")

    normalized_provider_message_id = provider_message_id.strip()
    normalized_provider_attachment_id = provider_attachment_id.strip()
    if not normalized_provider_message_id or not normalized_provider_attachment_id:
        raise HTTPException(status_code=400, detail="provider_message_id and provider_attachment_id are required")
    existing = db.execute(
        select(models.EmailIngestionEvent).where(
            models.EmailIngestionEvent.route_id == route.id,
            models.EmailIngestionEvent.provider_message_id == normalized_provider_message_id,
            models.EmailIngestionEvent.provider_attachment_id == normalized_provider_attachment_id,
        )
    ).scalar_one_or_none()
    if existing is not None:
        return EmailIngestionUploadResponse(
            status=EmailIngestionStatus.DUPLICATE,
            event_id=existing.id,
            job_id=existing.upload_job_id,
            detail="Duplicate provider message/attachment",
        )

    parsed_meta: dict[str, Any] | None = None
    if metadata_json and metadata_json.strip():
        try:
            parsed_meta = json.loads(metadata_json)
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(status_code=400, detail="metadata_json must be valid JSON") from exc

    content = await file.read()
    if not content:
        return EmailIngestionUploadResponse(status=EmailIngestionStatus.IGNORED, detail="Empty file")

    filename = Path(file.filename or "statement.pdf").name
    sha256 = hashlib.sha256(content).hexdigest()
    hash_existing = db.execute(
        select(models.EmailIngestionEvent).where(
            models.EmailIngestionEvent.profile_id == profile_id,
            models.EmailIngestionEvent.bank_code == route.bank_code,
            models.EmailIngestionEvent.attachment_sha256 == sha256,
        )
    ).scalar_one_or_none()
    if hash_existing is not None:
        return EmailIngestionUploadResponse(
            status=EmailIngestionStatus.DUPLICATE,
            event_id=hash_existing.id,
            job_id=hash_existing.upload_job_id,
            detail="Duplicate attachment hash",
        )

    if not filename.lower().endswith(".pdf"):
        event = models.EmailIngestionEvent(
            route_id=route.id,
            profile_id=profile_id,
            bank_code=route.bank_code,
            provider=mailbox.provider,
            provider_message_id=normalized_provider_message_id,
            provider_attachment_id=normalized_provider_attachment_id,
            internet_message_id=(internet_message_id or "").strip() or None,
            attachment_filename=filename,
            attachment_sha256=sha256,
            status=EmailIngestionStatus.IGNORED,
            error_message="Attachment is not PDF",
            provider_received_at=provider_received_at,
            processed_at=datetime.now(UTC),
            metadata_json=parsed_meta,
        )
        db.add(event)
        db.commit()
        db.refresh(event)
        return EmailIngestionUploadResponse(
            status=EmailIngestionStatus.IGNORED,
            event_id=event.id,
            detail="Attachment is not PDF",
        )

    meta_bank_code = str((parsed_meta or {}).get("bank_code") or "").strip().upper()
    if meta_bank_code and meta_bank_code != route.bank_code:
        event = models.EmailIngestionEvent(
            route_id=route.id,
            profile_id=profile_id,
            bank_code=route.bank_code,
            provider=mailbox.provider,
            provider_message_id=normalized_provider_message_id,
            provider_attachment_id=normalized_provider_attachment_id,
            internet_message_id=(internet_message_id or "").strip() or None,
            attachment_filename=filename,
            attachment_sha256=sha256,
            status=EmailIngestionStatus.IGNORED,
            error_message=f"Bank mismatch: route={route.bank_code}, metadata={meta_bank_code}",
            provider_received_at=provider_received_at,
            processed_at=datetime.now(UTC),
            metadata_json=parsed_meta,
        )
        db.add(event)
        db.commit()
        db.refresh(event)
        return EmailIngestionUploadResponse(
            status=EmailIngestionStatus.IGNORED,
            event_id=event.id,
            detail="Bank mismatch",
        )

    event = models.EmailIngestionEvent(
        route_id=route.id,
        profile_id=profile_id,
        bank_code=route.bank_code,
        provider=mailbox.provider,
        provider_message_id=normalized_provider_message_id,
        provider_attachment_id=normalized_provider_attachment_id,
        internet_message_id=(internet_message_id or "").strip() or None,
        attachment_filename=filename,
        attachment_sha256=sha256,
        status=EmailIngestionStatus.QUEUED,
        provider_received_at=provider_received_at,
        metadata_json=parsed_meta,
    )
    db.add(event)
    db.flush()

    staging = request.app.state.storage.save_binary(
        content=content,
        filename=f"email_ingest_{event.id}_{filename}",
        folder="staging",
        profile_key=profile_key,
    )

    try:
        payload_json = {
            "uploads": [
                {
                    "filename": filename,
                    "storage_key": staging.key,
                    "bank_code": route.bank_code,
                }
            ],
            "source": "email_ingestion",
            "event_id": event.id,
            "route_id": route.id,
        }
        dedupe_key = f"email-ingest:{route.id}:{normalized_provider_message_id}:{normalized_provider_attachment_id}"[:128]
        job, created, requeued = create_or_get_job(
            db,
            profile_id=profile_id,
            job_type=JobType.UPLOAD,
            payload_json=payload_json,
            idempotency_key=dedupe_key,
            auto_idempotency=False,
        )
        if created or requeued:
            request.app.state.job_dispatcher.publish(job.id)
        event.upload_job_id = job.id
        event.status = EmailIngestionStatus.UPLOADED
        event.processed_at = datetime.now(UTC)
        db.commit()
        return EmailIngestionUploadResponse(
            status=EmailIngestionStatus.UPLOADED,
            event_id=event.id,
            job_id=job.id,
            detail="Upload job queued",
        )
    except Exception as exc:  # noqa: BLE001
        event.status = EmailIngestionStatus.FAILED
        event.processed_at = datetime.now(UTC)
        event.error_message = str(exc)
        db.commit()
        raise HTTPException(status_code=500, detail="Failed to enqueue upload job") from exc
