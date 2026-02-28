from __future__ import annotations

import fnmatch
import os
from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.core.bank_config import load_app_config
from ccs_platform.adapters.banks.parsers import parse_adcb_statement, parse_enbd_statement, parse_fab_statement
from ccs_platform.domain.parsing.bank_samples import PARSER_SAMPLE_EXPECTED_COUNTS


def handle_parser_validate_job(db: Session, job: models.Job) -> dict[str, Any]:
    payload = job.payload_json or {}
    samples_dir = Path(payload.get("samples_dir", "")).expanduser()
    strict = bool(payload.get("strict", True))

    if not samples_dir.exists():
        raise RuntimeError(f"samples_dir does not exist: {samples_dir}")

    app_cfg = load_app_config()

    def latest_for(bank_code: str) -> Path | None:
        patterns = app_cfg.banks[bank_code].get("file_glob_patterns", [])
        candidates = [p for p in samples_dir.iterdir() if p.is_file() and p.suffix.lower() == ".pdf"]
        matched = [
            p for p in candidates if any(fnmatch.fnmatch(p.name.lower(), pt.lower()) for pt in patterns)
        ]
        if not matched:
            return None
        return max(matched, key=lambda p: p.stat().st_mtime)

    fab_file = latest_for("FAB")
    adcb_file = latest_for("ADCB")
    enbd_file = latest_for("ENBD")

    missing = [
        code
        for code, file_path in [("FAB", fab_file), ("ADCB", adcb_file), ("ENBD", enbd_file)]
        if file_path is None
    ]
    if missing:
        if strict:
            raise RuntimeError(f"Missing sample files for: {', '.join(missing)}")
        return {"missing": missing}

    adcb_password = os.getenv("ADCB_PDF_PASSWORD") or os.getenv("ADCB_CID")
    if not adcb_password:
        raise RuntimeError("ADCB_PDF_PASSWORD or ADCB_CID must be set for parser validation")

    counts = {
        "FAB": len(parse_fab_statement(fab_file).transactions),
        "ADCB": len(parse_adcb_statement(adcb_file, adcb_password).transactions),
        "ENBD": len(parse_enbd_statement(enbd_file).transactions),
    }

    mismatches = {
        bank_code: {"expected": PARSER_SAMPLE_EXPECTED_COUNTS[bank_code], "actual": actual}
        for bank_code, actual in counts.items()
        if actual != PARSER_SAMPLE_EXPECTED_COUNTS[bank_code]
    }

    if strict and mismatches:
        raise RuntimeError(f"Parser count mismatch: {mismatches}")

    return {
        "counts": counts,
        "expected": PARSER_SAMPLE_EXPECTED_COUNTS,
        "mismatches": mismatches,
    }
