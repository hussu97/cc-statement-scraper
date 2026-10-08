"""Bank detection from PDF text.

``_extract_pdf_text`` and ``_infer_bank_code_from_text`` are copied verbatim from
the legacy ``backend/ccs_platform/api/v1/endpoints/jobs.py`` (upload endpoint).
"""

from __future__ import annotations

from pathlib import Path


def _extract_pdf_text(pdf_path: Path, max_pages: int = 2, extra_passwords: list[str | None] | None = None) -> str:
    password_candidates: list[str | None] = [None] + (extra_passwords or [])

    def _extract_with_password(password: str | None) -> str | None:
        import pdfplumber  # noqa: PLC0415

        try:
            kwargs = {"password": password} if password else {}
            with pdfplumber.open(str(pdf_path), **kwargs) as pdf:
                chunks: list[str] = []
                for page in pdf.pages[:max_pages]:
                    chunks.append(page.extract_text() or "")
                return "\n".join(chunks)
        except Exception:  # noqa: BLE001
            return None

    for password in password_candidates:
        extracted = _extract_with_password(password)
        if extracted is not None:
            return extracted
    return ""


def _infer_bank_code_from_text(pdf_text: str) -> str | None:
    text = (pdf_text or "").upper()
    if not text.strip():
        return None

    # EIB statements usually include explicit Emirates Islamic markers.
    if "EMIRATES ISLAMIC BANK" in text or "EMIRATES ISLAMIC" in text or "EMIRATESISLAMIC" in text:
        return "EIB"
    if "EIB" in text and "STATEMENT PERIOD:" in text and "CARD TYPE:" in text:
        return "EIB"

    # ENBD statements reliably include these markers in headers.
    if "EMIRATES NBD" in text or "EMIRATES NATIONAL BANK OF DUBAI" in text:
        return "ENBD"
    if "STATEMENT PERIOD:" in text and "CARD TYPE:" in text:
        return "ENBD"

    # Mashreq statements include these bank markers.
    if "MASHREQ BANK" in text or "MASHREQBANK" in text:
        return "MASHREQ"
    if "MASHREQ" in text and "E-STATEMENT" in text:
        return "MASHREQ"

    # ADCB statements commonly include these section markers.
    if "ABU DHABI COMMERCIAL BANK" in text:
        return "ADCB"
    if "PREVIOUS BALANCE OUTSTANDING" in text or "NEW BALANCE OUTSTANDING" in text:
        return "ADCB"

    # FAB statements include these title/body phrases.
    if "FIRST ABU DHABI BANK" in text:
        return "FAB"
    if "SUPPLEMENTARY CARD" in text or "MAIN CARD PRODUCT" in text:
        return "FAB"
    if "CARD E-STATEMENT" in text and "AED" in text:
        return "FAB"

    # SIB statements and transaction history exports include these bank markers.
    if "SHARJAH ISLAMIC BANK" in text:
        return "SIB"
    if "SIB" in text and "ISLAMIC BANK" in text:
        return "SIB"
    if "SIB DIGITAL" in text and "STATEMENT" in text:
        return "SIB"
    if "TRANSACTION HISTORY" in text and "ACCOUNT NO." in text and "ACCOUNT TYPE" in text:
        return "SIB"

    return None


def detect_bank_code(pdf_path: Path, extra_passwords: list[str | None] | None = None) -> str | None:
    """Legacy ``_detect_bank_code_for_upload``: first two pages, trying each password."""
    return _infer_bank_code_from_text(_extract_pdf_text(pdf_path, extra_passwords=extra_passwords))
