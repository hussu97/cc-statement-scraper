from __future__ import annotations

from pydantic import BaseModel


class ProfileOut(BaseModel):
    key: str
    name: str
    is_default: bool
    banks: list[str]


class ProfileBanksPatchRequest(BaseModel):
    bank_codes: list[str]
