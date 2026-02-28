from __future__ import annotations

from pydantic import BaseModel, ConfigDict


class BankOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    code: str
    name: str
    supports_multi_month: bool
    supports_headless: bool
