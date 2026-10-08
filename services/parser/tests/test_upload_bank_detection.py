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


# ---------------------------------------------------------------- SRV-08: another bank in a line item
import pytest  # noqa: E402

_CROSS_BANK_CASES = [
    (
        "FAB",
        """
        MR JOHN DOE Main Card Product Statement Date Payment Due Date
        Main Card : 5492 84** **** 1234 CASHBACK CARD
        05-08-2025 05-08-2025 TRANSFER EMIRATES NBD AED 500.00 500.00
        First Abu Dhabi Bank P.J.S.C.
        """,
    ),
    (
        "ADCB",
        """
        PREVIOUS BALANCE OUTSTANDING NEW BALANCE OUTSTANDING
        12/08/2025 EMIRATES ISLAMIC TAKAFUL 250.00
        Abu Dhabi Commercial Bank PJSC
        """,
    ),
    (
        "MASHREQ",
        """
        Mashreq Bank PSC
        Credit Card E-Statement
        03 AUG 2025 EMIRATES NBD ATM DUBAI 200.00
        """,
    ),
    (
        "SIB",
        """
        Sharjah Islamic Bank
        SIB Digital Credit Card Statement
        04/08/2025 IPP TRANSFER MASHREQ BANK 1,000.00
        """,
    ),
    (
        "ENBD",
        """
        Statement Period: 01-Jan-25 to 31-Jan-25
        Card Type: Platinum
        02/01/2025 03/01/2025 EMIRATES ISLAMIC TAKAFUL DUBAI ARE 120.00
        Emirates NBD Bank PJSC
        """,
    ),
]


@pytest.mark.parametrize(("expected", "text"), _CROSS_BANK_CASES, ids=[c[0] for c in _CROSS_BANK_CASES])
def test_line_item_naming_another_bank_does_not_win(expected, text) -> None:
    assert _infer_bank_code_from_text(text) == expected


def test_layout_only_text_still_detected() -> None:
    assert _infer_bank_code_from_text("Statement Period: 01-Jan-25 to 31-Jan-25\nCard Type: Gold") == "ENBD"
    assert _infer_bank_code_from_text("EIB\nStatement Period: x\nCard Type: y") == "EIB"
    assert _infer_bank_code_from_text("TRANSACTION HISTORY\nAccount No. 1\nAccount Type CC") == "SIB"


def test_falls_back_to_legacy_rules_when_nothing_scores() -> None:
    assert _infer_bank_code_from_text("MASHREQ something") is None
    assert _infer_bank_code_from_text("SIB something ISLAMIC BANK") == "SIB"
