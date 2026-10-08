"""Run the LEGACY backend parser on a batch of PDFs and emit golden JSON.

Executed by ``build_golden.py`` with the backend interpreter
(``backend/.venv/bin/python``) and ``PYTHONPATH=backend``. It must not import
anything from ``ccs_parser``.

stdin:  JSON {"settings": {...}, "items": [{"path": str, "filename": str, "sha256": str}, ...]}
stdout: one JSON object per line, one per item.
"""

from __future__ import annotations

import json
import sys
import traceback
from pathlib import Path


def _iso(value):
    return value.isoformat() if value is not None else None


def _run_one(item: dict, settings: dict) -> dict:
    from ccs_platform.api.v1.endpoints.jobs import _extract_pdf_text, _infer_bank_code_from_text
    from ccs_platform.application.statements.parser_adapter import parse_statement_pdf
    from ccs_platform.domain.parsing.models import ParserError
    from ccs_platform.domain.statements.identity import resolve_statement_identity

    path = Path(item["path"])
    out: dict = {
        "sha256": item["sha256"],
        "source_path": str(path),
        "filename": item["filename"],
        "settings": settings,
        "bank_code": None,
        "status": "ok",
        "error": None,
        "statements": [],
    }
    passwords = [
        settings.get(k) or None
        for k in ["FAB_PDF_PASSWORD", "ADCB_PDF_PASSWORD", "ADCB_CID", "ENBD_PDF_PASSWORD", "SIB_PDF_PASSWORD"]
    ]
    bank = (_infer_bank_code_from_text(_extract_pdf_text(path, extra_passwords=passwords)) or "").upper().strip()
    if not bank:
        out["status"] = "undetected"
        return out
    out["bank_code"] = bank

    try:
        parsed = parse_statement_pdf(bank, path, source_filename=item["filename"], runtime_settings=settings)
    except ParserError as exc:
        out["status"] = "error"
        out["error"] = {"code": exc.code, "message": exc.message}
        return out
    except Exception as exc:  # noqa: BLE001
        out["status"] = "error"
        out["error"] = {
            "code": "EXCEPTION",
            "message": f"{type(exc).__name__}: {exc}",
            "traceback": traceback.format_exc(limit=5),
        }
        return out

    statements = parsed if isinstance(parsed, list) else [parsed]
    for st in statements:
        identity = resolve_statement_identity(parsed_statement=st, pdf_checksum_sha256=item["sha256"])
        out["statements"].append(
            {
                "bank_code": st.bank_code,
                "statement_reference": identity.statement_reference,
                "reference_source": identity.reference_source,
                "statement_date": _iso(identity.statement_date),
                "period_start": _iso(st.statement_period_start),
                "period_end": _iso(st.statement_period_end),
                "primary_card_last4": st.primary_card_last4,
                "card_holder": st.card_holder,
                "card_type": st.card_type,
                "pdf_type": (st.metadata or {}).get("pdf_type"),
                "due_date": (st.metadata or {}).get("due_date"),
                "warnings": list(st.warnings),
                "lines": [
                    {
                        "line_no": ln.line_no,
                        "txn_date": _iso(ln.transaction_date),
                        "posting_date": _iso(ln.posting_date),
                        "merchant_raw": ln.merchant_raw,
                        "merchant_normalized": ln.merchant_normalized,
                        "amount_original": ln.amount_original,
                        "amount_aed": ln.amount_aed,
                        "currency_original": ln.currency_original,
                        "direction": ln.direction,
                        "kind": ln.transaction_kind,
                        "country_code": ln.country_code,
                        "card_last4": ln.card_last4,
                        "fingerprint": ln.fingerprint,
                    }
                    for ln in st.lines
                ],
            }
        )
    return out


def main() -> None:
    payload = json.load(sys.stdin)
    settings = payload.get("settings") or {}
    for item in payload["items"]:
        try:
            result = _run_one(item, settings)
        except Exception as exc:  # noqa: BLE001
            result = {
                "sha256": item["sha256"],
                "source_path": item["path"],
                "filename": item["filename"],
                "settings": settings,
                "bank_code": None,
                "status": "error",
                "error": {"code": "RUNNER_EXCEPTION", "message": f"{type(exc).__name__}: {exc}"},
                "statements": [],
            }
        sys.stdout.write(json.dumps(result) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
