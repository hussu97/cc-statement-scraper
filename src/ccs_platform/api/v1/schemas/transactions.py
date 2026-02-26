from __future__ import annotations

from pydantic import BaseModel


class TransactionCategoryPatch(BaseModel):
    category: str


class TransactionBulkCategoryPatch(BaseModel):
    line_ids: list[int]
    category: str
