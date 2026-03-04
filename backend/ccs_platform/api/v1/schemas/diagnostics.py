from __future__ import annotations

from pydantic import BaseModel


class ParserValidateRequest(BaseModel):
    samples_dir: str
    strict: bool = True


