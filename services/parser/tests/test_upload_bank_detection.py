from __future__ import annotations

from ccs_parser.detection import _infer_bank_code_from_text


def test_infer_bank_code_from_text_identifies_fab() -> None:
    text = """
    FIRST ABU DHABI BANK
    Supplementary Card : XX****1234
    """
    assert _infer_bank_code_from_text(text) == "FAB"


def test_infer_bank_code_from_text_identifies_adcb() -> None:
    text = """
    Abu Dhabi Commercial Bank
    PREVIOUS BALANCE OUTSTANDING
    """
    assert _infer_bank_code_from_text(text) == "ADCB"


def test_infer_bank_code_from_text_identifies_enbd() -> None:
    text = """
    Emirates NBD
    Statement Period: 01-Jan-25 to 31-Jan-25
    Card Type: Platinum
    """
    assert _infer_bank_code_from_text(text) == "ENBD"


def test_infer_bank_code_from_text_identifies_eib() -> None:
    text = """
    Emirates Islamic Bank
    Statement Period: 01-Jan-25 to 31-Jan-25
    Card Type: Platinum
    """
    assert _infer_bank_code_from_text(text) == "EIB"


def test_infer_bank_code_from_text_returns_none_when_unknown() -> None:
    assert _infer_bank_code_from_text("Random PDF with no known bank markers") is None


def test_infer_bank_code_from_text_identifies_sib() -> None:
    text = """
    Sharjah Islamic Bank
    SIB Digital Credit Card Statement
    """
    assert _infer_bank_code_from_text(text) == "SIB"


def test_infer_bank_code_from_text_identifies_mashreq() -> None:
    text = """
    Mashreq Bank PSC
    Credit Card E-Statement
    """
    assert _infer_bank_code_from_text(text) == "MASHREQ"
