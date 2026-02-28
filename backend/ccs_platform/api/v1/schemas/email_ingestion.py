from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from ccs_platform.db.models.enums import EmailIngestionStatus, EmailProvider


class EmailMailboxOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    profile_id: int
    provider: EmailProvider
    mailbox_email: str
    display_name: str | None
    is_active: bool
    sync_state_json: dict | None
    watch_expiration_at: datetime | None
    last_sync_at: datetime | None
    last_error_at: datetime | None
    last_error_message: str | None
    created_at: datetime
    updated_at: datetime


class EmailMailboxCreate(BaseModel):
    provider: EmailProvider
    mailbox_email: str = Field(min_length=3, max_length=320)
    display_name: str | None = Field(default=None, max_length=256)
    is_active: bool = True


class EmailMailboxPatch(BaseModel):
    mailbox_email: str | None = Field(default=None, min_length=3, max_length=320)
    display_name: str | None = Field(default=None, max_length=256)
    is_active: bool | None = None


class EmailBankRouteOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    profile_id: int
    bank_code: str
    mailbox_id: int
    provider: EmailProvider
    mailbox_email: str
    sender_allowlist_json: list[str] | None
    subject_keywords_json: list[str] | None
    attachment_filename_regex: str | None
    gmail_label_filter_json: dict | None
    is_active: bool
    created_at: datetime
    updated_at: datetime


class EmailBankRouteUpsert(BaseModel):
    mailbox_id: int
    sender_allowlist_json: list[str] | None = None
    subject_keywords_json: list[str] | None = None
    attachment_filename_regex: str | None = Field(default=None, max_length=512)
    gmail_label_filter_json: dict | None = None
    is_active: bool = True


class EmailIngestionEventOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    route_id: int
    profile_id: int
    bank_code: str
    provider: EmailProvider
    provider_message_id: str
    provider_attachment_id: str
    internet_message_id: str | None
    attachment_filename: str
    attachment_sha256: str
    status: EmailIngestionStatus
    upload_job_id: int | None
    error_message: str | None
    provider_received_at: datetime | None
    processed_at: datetime | None
    metadata_json: dict | None
    created_at: datetime


class PaginatedEmailMailboxes(BaseModel):
    items: list[EmailMailboxOut]
    total: int
    page: int
    page_size: int


class PaginatedEmailRoutes(BaseModel):
    items: list[EmailBankRouteOut]
    total: int
    page: int
    page_size: int


class PaginatedEmailIngestionEvents(BaseModel):
    items: list[EmailIngestionEventOut]
    total: int
    page: int
    page_size: int


class OAuthAccessTokenRequest(BaseModel):
    mailbox_id: int


class OAuthAccessTokenOut(BaseModel):
    provider: EmailProvider
    access_token: str
    token_type: str
    expires_at: datetime


class EmailIngestionUploadResponse(BaseModel):
    status: EmailIngestionStatus
    event_id: int | None = None
    job_id: int | None = None
    detail: str | None = None


class EmailMailboxSyncStatePatch(BaseModel):
    sync_state_json: dict | None = None
    watch_expiration_at: datetime | None = None
    last_sync_at: datetime | None = None
    last_error_at: datetime | None = None
    last_error_message: str | None = None


class ServiceApiTokenCreate(BaseModel):
    name: str = Field(min_length=1, max_length=128)
    scopes: list[str]


class ServiceApiTokenOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    profile_id: int
    name: str
    token_prefix: str
    scopes_json: list[str] | None
    is_active: bool
    last_used_at: datetime | None
    created_at: datetime
    revoked_at: datetime | None


class ServiceApiTokenCreated(BaseModel):
    token: str
    item: ServiceApiTokenOut


class OAuthConfigOut(BaseModel):
    provider: EmailProvider
    auth_url: str | None
    configured: bool


class OAuthCodeExchangeRequest(BaseModel):
    provider: EmailProvider
    code: str = Field(min_length=1)


class OAuthCodeExchangeOut(BaseModel):
    provider: EmailProvider
    refresh_token: str
