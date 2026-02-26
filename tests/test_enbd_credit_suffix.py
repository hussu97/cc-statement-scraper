from __future__ import annotations

from pathlib import Path

from ccs_platform.adapters.banks.parsers import enbd


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
