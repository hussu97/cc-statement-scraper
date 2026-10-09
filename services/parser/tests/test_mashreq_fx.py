"""DP-11: Mashreq foreign rows report their currency, original amount and printed rate."""

from __future__ import annotations

from datetime import date
from pathlib import Path

from ccs_parser.banks.mashreq import BANK_NAME, _split_fx_residue
from ccs_parser.domain.parsing.utils import fingerprint_for, merchant_normalize
from ccs_parser.service import parse_document
from tests.synthetic.cases import CASES


def test_split_fx_residue() -> None:
    assert _split_fx_residue("noodle housekuala lumpur 2400000001 MYR 1,250.40 @0.9310") == (
        "noodle housekuala lumpur",
        "MYR",
        1250.40,
        0.931,
    )
    # AED rows have the reference only; the legacy regex already strips it.
    assert _split_fx_residue("corner grocerydubai") is None
    assert _split_fx_residue("shop 2400000001 AED 10.00 @1.0000") is None
    assert _split_fx_residue("shop 2400000001 MYR 10.00 @0") is None


def _lines(tmp_path: Path) -> list[dict]:
    pdf = CASES["mashreq_statement"].write(tmp_path / "s.pdf")
    return parse_document(pdf)["statements"][0]["lines"]


def test_foreign_rows(tmp_path: Path) -> None:
    by_desc = {ln["description_raw"]: ln for ln in _lines(tmp_path)}
    debit = by_desc["noodle housekuala lumpur"]
    assert (debit["currency_original"], debit["amount_original"], debit["amount_aed"], debit["fx_rate"]) == (
        "MYR",
        "500.00",
        "470.00",
        "0.94",
    )
    assert debit["merchant_normalized"] == "NOODLE HOUSE KUALA LUMPUR"
    assert debit["direction"] == "debit"
    credit = by_desc["ticket officetokyo"]
    assert (credit["currency_original"], credit["amount_original"], credit["amount_aed"]) == (
        "JPY",
        "4000.00",
        "100.00",
    )
    assert credit["direction"] == "credit"
    aed = by_desc["corner grocerydubai"]
    assert (aed["currency_original"], aed["amount_original"], aed["fx_rate"]) == ("AED", "120.00", "1")


def test_legacy_fingerprint_is_unchanged(tmp_path: Path) -> None:
    """Legacy category choices are keyed by the fingerprint, which legacy computed from the
    unsplit description and the AED amount."""
    line = next(ln for ln in _lines(tmp_path) if ln["currency_original"] == "MYR")
    legacy_desc = "noodle housekuala lumpur 2400000001 MYR 500.00 @0.9400"
    expected = fingerprint_for(BANK_NAME, "4000", date(2026, 1, 8), 470.0, merchant_normalize(legacy_desc))
    assert line["legacy_fingerprint"] == expected
