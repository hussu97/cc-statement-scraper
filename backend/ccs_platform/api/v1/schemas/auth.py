from __future__ import annotations

from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    email: str = Field(min_length=3, max_length=256)
    password: str = Field(min_length=1, max_length=256)


class AuthUserOut(BaseModel):
    email: str
    display_name: str
    default_profile_key: str
    role: str


class LoginResponse(BaseModel):
    user: AuthUserOut
