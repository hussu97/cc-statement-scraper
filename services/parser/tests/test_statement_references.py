from __future__ import annotations

from pathlib import Path

import pytest

from ccs_parser import parser_adapter
from ccs_parser.banks.adcb import _extract_statement_reference as extract_adcb_reference
from ccs_parser.banks.enbd import _extract_statement_reference as extract_enbd_reference
from ccs_parser.banks.fab import _extract_statement_reference as extract_fab_reference
from ccs_parser.domain.parsing.models import StatementParseResult


def _result(*, source_name: str, metadata: dict[str, str | None]) -> StatementParseResult:
    return StatementParseResult(
        bank_code="FAB",
        bank_name="First Abu Dhabi Bank",
        source_pdf=Path(source_name),
        statement_month="2026-02",
        transactions=[],
        warnings=[],
        metadata=metadata,
    )


def test_parse_statement_pdf_does_not_use_temp_filename_timestamp_as_reference(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    result = _result(
        source_name="FAB_20260225194316_CreditCardEStatement_9203.PDF",
        metadata={"statement_date": "2026-02-01", "statement_reference": None},
    )
    monkeypatch.setattr(parser_adapter, "parse_statement_for_bank", lambda *_: result)

    parsed = parser_adapter.parse_statement_pdf(
        "FAB",
        tmp_path / "statement.pdf",
        source_filename="CreditCardEStatement_9203.PDF",
    )

    assert parsed.statement_reference_raw is None


def test_parse_statement_pdf_extracts_reference_from_original_filename(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    result = _result(
        source_name="FAB_20260225194316_CreditCardEStatement_9203.PDF",
        metadata={"statement_date": "2026-02-01", "statement_reference": None},
    )
    monkeypatch.setattr(parser_adapter, "parse_statement_for_bank", lambda *_: result)

    parsed = parser_adapter.parse_statement_pdf(
        "FAB",
        tmp_path / "statement.pdf",
        source_filename="FAB Statement Ref-ABC123456.pdf",
    )

    assert parsed.statement_reference_raw == "ABC123456"


@pytest.mark.parametrize(
    "extractor",
    [extract_fab_reference, extract_enbd_reference, extract_adcb_reference],
)
def test_bank_reference_extractors_ignore_label_without_value(extractor) -> None:
    assert extractor(["Statement Reference", "Reference", "Ref"]) is None


@pytest.mark.parametrize(
    "extractor",
    [extract_fab_reference, extract_enbd_reference, extract_adcb_reference],
)
def test_bank_reference_extractors_capture_reference_with_digits(extractor) -> None:
    assert extractor(["Statement Reference: STMT123456"]) == "STMT123456"
