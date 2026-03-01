from __future__ import annotations

import os
from pathlib import Path

from ccs_platform.domain.parsing.models import ParserError, StatementParseResult


def parse_statement_for_bank(bank_code: str, pdf_path: str | Path) -> StatementParseResult:
    # Parsers are imported lazily so that pdfplumber (~15 MB) is not loaded
    # at startup — only when the first parse job actually runs.
    code = bank_code.upper()

    if code == "FAB":
        from ccs_platform.adapters.banks.parsers.fab import parse_fab_statement  # noqa: PLC0415
        return parse_fab_statement(pdf_path)

    if code == "ADCB":
        pdf_password = os.getenv("ADCB_PDF_PASSWORD") or os.getenv("ADCB_CID")
        if not pdf_password:
            raise ParserError(
                "PDF_DECRYPT_FAILED",
                "ADCB statement requires ADCB_PDF_PASSWORD (or ADCB_CID fallback).",
            )
        from ccs_platform.adapters.banks.parsers.adcb import parse_adcb_statement  # noqa: PLC0415
        return parse_adcb_statement(pdf_path, pdf_password)

    if code == "ENBD":
        from ccs_platform.adapters.banks.parsers.enbd import parse_enbd_statement  # noqa: PLC0415
        return parse_enbd_statement(pdf_path)

    if code == "EIB":
        from ccs_platform.adapters.banks.parsers.eib import parse_eib_statement  # noqa: PLC0415
        return parse_eib_statement(pdf_path)

    if code == "SIB":
        pdf_password = os.getenv("SIB_PDF_PASSWORD")
        if not pdf_password:
            raise ParserError(
                "PDF_DECRYPT_FAILED",
                "SIB statement requires SIB_PDF_PASSWORD.",
            )
        from ccs_platform.adapters.banks.parsers.sib import parse_sib_statement  # noqa: PLC0415
        return parse_sib_statement(pdf_path, pdf_password)

    if code == "MASHREQ":
        from ccs_platform.adapters.banks.parsers.mashreq import parse_mashreq_statement  # noqa: PLC0415
        return parse_mashreq_statement(pdf_path)

    raise ParserError("UNSUPPORTED_BANK", f"Unsupported bank code: {bank_code}")
