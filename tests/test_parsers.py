from __future__ import annotations

from pathlib import Path

import pytest

from ccs_platform.domain.parsing.models import ParserError
from ccs_platform.adapters.banks.parsers.adcb import parse_adcb_statement
from ccs_platform.adapters.banks.parsers.enbd import parse_enbd_statement
from ccs_platform.adapters.banks.parsers.fab import parse_fab_statement


SAMPLES_DIR = Path("/Users/hussainabbasi/Downloads")
FAB_SAMPLE = SAMPLES_DIR / "FAB Credit Card E-Statement.PDF"
ADCB_SAMPLE = SAMPLES_DIR / "ADCB Statement.pdf"
ENBD_SAMPLE = SAMPLES_DIR / "Emirates NBD E-Statement Jan 29 2026.pdf"


pytestmark = pytest.mark.skipif(
    not (FAB_SAMPLE.exists() and ADCB_SAMPLE.exists() and ENBD_SAMPLE.exists()),
    reason="Sample PDFs are required in Downloads",
)


def test_fab_parser_golden_count() -> None:
    result = parse_fab_statement(FAB_SAMPLE)
    assert len(result.transactions) == 49


def test_fab_supplementary_card_context() -> None:
    result = parse_fab_statement(FAB_SAMPLE)
    supplementary_rows = [tx for tx in result.transactions if tx.card_last4 == "2132"]
    assert supplementary_rows, "Expected supplementary card rows with last4=2132"
    assert any("PAPPAROTI" in tx.merchant_normalized for tx in supplementary_rows)


def test_adcb_parser_golden_count() -> None:
    result = parse_adcb_statement(ADCB_SAMPLE, "13058089")
    assert len(result.transactions) == 9


def test_adcb_fx_linkage_and_payment_sign() -> None:
    result = parse_adcb_statement(ADCB_SAMPLE, "13058089")
    payment_rows = [tx for tx in result.transactions if tx.transaction_kind == "payment"]
    assert payment_rows and payment_rows[0].amount_aed < 0

    non_aed_rows = [tx for tx in result.transactions if tx.currency_original != "AED"]
    assert non_aed_rows and any(tx.fx_rate_to_aed is not None for tx in non_aed_rows)


def test_adcb_wrong_password_raises_pdf_decrypt_failed() -> None:
    with pytest.raises(ParserError) as exc:
        parse_adcb_statement(ADCB_SAMPLE, "wrong-password")
    assert exc.value.code == "PDF_DECRYPT_FAILED"


def test_enbd_parser_golden_count() -> None:
    result = parse_enbd_statement(ENBD_SAMPLE)
    assert len(result.transactions) == 8
    assert result.statement_month == "2026-01"
