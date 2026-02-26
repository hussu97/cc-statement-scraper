from __future__ import annotations

from pathlib import Path

import pytest

from ccs_platform.domain.parsing.models import ParserError
from ccs_platform.adapters.banks.parsers.sib import parse_sib_statement


def test_sib_missing_password_raises_pdf_decrypt_failed() -> None:
    with pytest.raises(ParserError) as exc:
        parse_sib_statement(Path("dummy-sib.pdf"), "")
    assert exc.value.code == "PDF_DECRYPT_FAILED"


def test_sib_unknown_layout_raises_explicit_error(monkeypatch: pytest.MonkeyPatch) -> None:
    class _FakePage:
        def extract_text(self) -> str:
            return "This PDF has no tabular transactions"

    class _FakePdf:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb) -> None:
            return None

        @property
        def pages(self):
            return [_FakePage()]

    monkeypatch.setattr(
        "ccs_platform.adapters.banks.parsers.sib.pdfplumber.open",
        lambda *_args, **_kwargs: _FakePdf(),
    )

    with pytest.raises(ParserError) as exc:
        parse_sib_statement(Path("dummy-sib.pdf"), "281197")
    assert exc.value.code == "UNSUPPORTED_LAYOUT"
