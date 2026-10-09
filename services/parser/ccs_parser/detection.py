"""Bank detection from PDF text.

``_extract_pdf_text`` and ``_legacy_infer_bank_code_from_text`` are copied verbatim
from the legacy ``backend/ccs_platform/api/v1/endpoints/jobs.py`` (upload endpoint).

The legacy check is first-match in a fixed bank order, so a transaction line naming
another bank ("TRANSFER EMIRATES NBD" on a FAB statement) won (audit SRV-08).
``_infer_bank_code_from_text`` now scores every bank instead:

* name markers (legal name 3, brand 2) are only searched outside transaction rows
  (lines starting with a date), so merchants and transfers can't vote;
* layout markers (labels printed by the bank's statement template) add up to 3;
* highest score wins; ties go to the stronger name, then layout, then legacy order.

When nothing scores, the legacy rules run on the full text as before.
"""

from __future__ import annotations

import re
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


def _legacy_infer_bank_code_from_text(pdf_text: str) -> str | None:
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


# Legacy check order, used as the final tie-break.
_BANK_ORDER = ("EIB", "ENBD", "MASHREQ", "ADCB", "FAB", "SIB")

# (bank, marker, weight). Matched on header/summary text only (transaction rows removed).
_NAME_MARKERS: tuple[tuple[str, str, int], ...] = (
    ("FAB", "FIRST ABU DHABI BANK", 3),
    ("SIB", "SHARJAH ISLAMIC BANK", 3),
    ("ADCB", "ABU DHABI COMMERCIAL BANK", 3),
    ("EIB", "EMIRATES ISLAMIC BANK", 3),
    ("EIB", "EMIRATES ISLAMIC", 2),
    ("EIB", "EMIRATESISLAMIC", 2),
    ("ENBD", "EMIRATES NATIONAL BANK OF DUBAI", 3),
    ("ENBD", "EMIRATES NBD", 2),
    ("MASHREQ", "MASHREQBANK", 3),
    ("MASHREQ", "MASHREQ BANK", 2),
)

# A line that starts with a date is a transaction row (merchant / transfer text).
_TXN_ROW_RE = re.compile(r"^\s*\d{1,2}[/\-. ](?:\d{1,2}|[A-Z]{3})(?:[/\-. ]\d{2,4})?\b")


def _word(token: str, text: str) -> bool:
    return re.search(rf"\b{token}\b", text) is not None


def _shared_enbd_template(text: str) -> bool:
    return "STATEMENT PERIOD:" in text and "CARD TYPE:" in text


def _layout_scores(text: str) -> dict[str, int]:
    """Statement-template labels. ENBD and EIB share one template; names tell them apart."""
    scores: dict[str, int] = {}

    def vote(bank: str, weight: int) -> None:
        scores[bank] = max(scores.get(bank, 0), weight)

    if _shared_enbd_template(text):
        vote("ENBD", 3)
        if _word("EIB", text):
            vote("EIB", 4)
    if "MASHREQ" in text and "E-STATEMENT" in text:
        vote("MASHREQ", 1)
    if "PREVIOUS BALANCE OUTSTANDING" in text or "NEW BALANCE OUTSTANDING" in text:
        vote("ADCB", 3)
    if "SUPPLEMENTARY CARD" in text or "MAIN CARD PRODUCT" in text:
        vote("FAB", 3)
    if "CARD E-STATEMENT" in text and "AED" in text:
        vote("FAB", 1)
    if "SIB DIGITAL" in text and "STATEMENT" in text:
        vote("SIB", 3)
    if "TRANSACTION HISTORY" in text and "ACCOUNT NO." in text and "ACCOUNT TYPE" in text:
        vote("SIB", 3)
    if "STATEMENT DETAILS" in text and "CARD ISSUER SIB" in text:
        vote("SIB", 3)
    if _word("SIB", text) and "ISLAMIC BANK" in text:
        vote("SIB", 1)
    return scores


def _infer_bank_code_from_text(pdf_text: str) -> str | None:
    text = (pdf_text or "").upper()
    if not text.strip():
        return None
    header = "\n".join(line for line in text.splitlines() if not _TXN_ROW_RE.match(line))

    names: dict[str, int] = {}
    for bank, marker, weight in _NAME_MARKERS:
        if marker in header:
            names[bank] = max(names.get(bank, 0), weight)
    layouts = _layout_scores(text)
    if "EIB" in names and _shared_enbd_template(text):
        # The Emirates NBD group template, branded Emirates Islamic.
        layouts["EIB"] = max(layouts.get("EIB", 0), 3)

    candidates = set(names) | set(layouts)
    if not candidates:
        return _legacy_infer_bank_code_from_text(text)

    def rank(bank: str) -> tuple[int, int, int, int]:
        name, layout = names.get(bank, 0), layouts.get(bank, 0)
        return (name + layout, name, layout, -_BANK_ORDER.index(bank))

    return max(candidates, key=rank)


def detect_bank_code(pdf_path: Path, extra_passwords: list[str | None] | None = None) -> str | None:
    """Legacy ``_detect_bank_code_for_upload``: first two pages, trying each password."""
    return _infer_bank_code_from_text(_extract_pdf_text(pdf_path, extra_passwords=extra_passwords))
