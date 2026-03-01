from __future__ import annotations

import pytest

from pathlib import Path

from ccs_platform.adapters.banks.parsers import enbd
from ccs_platform.domain.parsing.models import ParserError


class _FakePage:
    def __init__(self, text: str) -> None:
        self._text = text

    def extract_text(self) -> str:
        return self._text


class _FakePdf:
    def __init__(self, text: str) -> None:
        self.pages = [_FakePage(text)]

    def __enter__(self) -> "_FakePdf":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        return False


def test_enbd_parser_extracts_cr_suffix_as_credit(monkeypatch) -> None:
    sample_text = "\n".join(
        [
            "Statement Period: 01-Jan-26 to 31-Jan-26",
            "01/01/2026 02/01/2026 NOON FOOD UAE 840.00CR",
            "03/01/2026 04/01/2026 CARREFOUR UAE 120.50",
            "05/01/2026 06/01/2026 AMAZON UAE 25.00 CR",
        ]
    )

    monkeypatch.setattr(enbd.pdfplumber, "open", lambda *_args, **_kwargs: _FakePdf(sample_text))

    result = enbd.parse_enbd_statement(Path("dummy-enbd.pdf"))

    assert len(result.transactions) == 3
    assert result.transactions[0].amount_aed == -840.0
    assert result.transactions[0].amount_original == -840.0
    assert result.transactions[1].amount_aed == 120.5
    assert result.transactions[2].amount_aed == -25.0


def test_enbd_parser_decrypts_with_password_on_retry(monkeypatch) -> None:
    """Parser retries with password when the first open attempt raises (encrypted PDF)."""
    sample_text = "\n".join(
        [
            "Statement Period: 01-Jan-26 to 31-Jan-26",
            "01/01/2026 02/01/2026 NOON FOOD UAE 840.00CR",
        ]
    )

    call_count = 0

    def _fake_open(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        if "password" not in kwargs:
            raise Exception("PDF is encrypted")
        return _FakePdf(sample_text)

    monkeypatch.setattr(enbd.pdfplumber, "open", _fake_open)

    result = enbd.parse_enbd_statement(Path("dummy-enbd.pdf"), pdf_password="secret")

    assert len(result.transactions) == 1
    assert result.transactions[0].amount_aed == -840.0
    assert call_count == 2  # first without password (raises), then with password


def test_enbd_parser_raises_if_encrypted_and_no_password(monkeypatch) -> None:
    """Parser raises ParserError when PDF is encrypted but no password is supplied."""

    def _fake_open(*args, **kwargs):
        if "password" not in kwargs:
            raise Exception("PDF is encrypted")
        return _FakePdf("")

    monkeypatch.setattr(enbd.pdfplumber, "open", _fake_open)

    with pytest.raises(ParserError, match="ENBD_PDF_PASSWORD"):
        enbd.parse_enbd_statement(Path("dummy-enbd.pdf"))
