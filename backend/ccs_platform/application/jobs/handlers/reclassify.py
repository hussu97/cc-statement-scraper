from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.domain.categorization.engine import reclassify_statement_lines


def handle_reclassify_job(db: Session, job: models.Job) -> dict[str, Any]:
    payload = job.payload_json or {}
    statement_ids = payload.get("statement_ids")
    updated = reclassify_statement_lines(db, statement_ids=statement_ids, profile_id=job.profile_id)
    db.commit()
    return {"updated_line_count": updated}
