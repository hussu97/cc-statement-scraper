from __future__ import annotations

import os
from pathlib import Path

from ccs_platform.domain.parsing.models import ParserError, StatementParseResult
from ccs_platform.adapters.banks.parsers.adcb import parse_adcb_statement
from ccs_platform.adapters.banks.parsers.enbd import parse_enbd_statement
from ccs_platform.adapters.banks.parsers.fab import parse_fab_statement
from ccs_platform.adapters.banks.parsers.sib import parse_sib_statement



def parse_statement_for_bank(bank_code: str, pdf_path: str | Path) -> StatementParseResult:
    code = bank_code.upper()

    if code == "FAB":
        return parse_fab_statement(pdf_path)

    if code == "ADCB":
        pdf_password = os.getenv("ADCB_PDF_PASSWORD") or os.getenv("ADCB_CID")
        if not pdf_password:
            raise ParserError(
                "PDF_DECRYPT_FAILED",
                "ADCB statement requires ADCB_PDF_PASSWORD (or ADCB_CID fallback).",
            )
        return parse_adcb_statement(pdf_path, pdf_password)

    if code == "ENBD":
        return parse_enbd_statement(pdf_path)

    if code == "SIB":
        pdf_password = os.getenv("SIB_PDF_PASSWORD")
        if not pdf_password:
            raise ParserError(
                "PDF_DECRYPT_FAILED",
                "SIB statement requires SIB_PDF_PASSWORD.",
            )
        return parse_sib_statement(pdf_path, pdf_password)

    raise ParserError("UNSUPPORTED_BANK", f"Unsupported bank code: {bank_code}")
