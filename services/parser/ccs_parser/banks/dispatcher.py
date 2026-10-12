from __future__ import annotations

from pathlib import Path

from ccs_parser.domain.parsing.models import ParserError, StatementParseResult


def parse_statement_for_bank(
    bank_code: str,
    pdf_path: str | Path,
    settings: dict[str, str] | None = None,
) -> StatementParseResult | list[StatementParseResult]:
    # Parsers are imported lazily so that pdfplumber (~15 MB) is not loaded
    # at startup — only when the first parse job actually runs.
    _s = settings or {}
    code = bank_code.upper()

    if code == "FAB":
        from ccs_parser.banks.fab import parse_fab_statement  # noqa: PLC0415
        # Password is optional — scraper/manual PDFs are unencrypted; email-sourced
        # PDFs are encrypted with a profile-specific password.
        pdf_password = _s.get("FAB_PDF_PASSWORD") or None
        return parse_fab_statement(pdf_path, pdf_password)

    if code == "ADCB":
        pdf_password = _s.get("ADCB_PDF_PASSWORD") or _s.get("ADCB_CID")
        if not pdf_password:
            raise ParserError(
                "PDF_DECRYPT_FAILED",
                "ADCB statement requires ADCB_PDF_PASSWORD (or ADCB_CID fallback).",
            )
        from ccs_parser.banks.adcb import parse_adcb_statement  # noqa: PLC0415
        return parse_adcb_statement(pdf_path, pdf_password)

    if code == "ENBD":
        from ccs_parser.banks.enbd import parse_enbd_statement  # noqa: PLC0415
        # Password is optional — scraper/manual PDFs are unencrypted; email-sourced
        # PDFs are encrypted with a profile-specific password.
        pdf_password = _s.get("ENBD_PDF_PASSWORD") or None
        return parse_enbd_statement(pdf_path, pdf_password)

    if code == "EIB":
        from ccs_parser.banks.eib import parse_eib_statement  # noqa: PLC0415
        # Optional, like FAB/ENBD: emailed statements are encrypted (audit X-17).
        return parse_eib_statement(pdf_path, _s.get("EIB_PDF_PASSWORD") or None)

    if code == "SIB":
        pdf_password = _s.get("SIB_PDF_PASSWORD")
        from ccs_parser.banks.sib import (  # noqa: PLC0415
            is_transaction_history,
            parse_sib_statement,
            parse_sib_transaction_history,
        )
        import pdfplumber  # noqa: PLC0415
        try:
            open_kwargs: dict = {"password": pdf_password} if pdf_password else {}
            with pdfplumber.open(str(pdf_path), **open_kwargs) as _pdf:
                _first_lines = []
                for _page in _pdf.pages[:2]:
                    _first_lines.extend((_page.extract_text() or "").splitlines())
        except Exception:  # noqa: BLE001
            _first_lines = []

        if is_transaction_history(_first_lines):
            return parse_sib_transaction_history(pdf_path, pdf_password)

        if not pdf_password:
            raise ParserError(
                "PDF_DECRYPT_FAILED",
                "SIB statement requires SIB_PDF_PASSWORD.",
            )
        return parse_sib_statement(pdf_path, pdf_password)

    if code == "MASHREQ":
        from ccs_parser.banks.mashreq import parse_mashreq_statement  # noqa: PLC0415
        return parse_mashreq_statement(pdf_path, _s.get("MASHREQ_PDF_PASSWORD") or None)

    if code == "WIO":
        from ccs_parser.banks.wio import parse_wio_statement  # noqa: PLC0415
        # Wio sends its statements unencrypted; no password setting exists for it.
        return parse_wio_statement(pdf_path)

    raise ParserError("UNSUPPORTED_BANK", f"Unsupported bank code: {bank_code}")
