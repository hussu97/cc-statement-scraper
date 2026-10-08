from __future__ import annotations

from datetime import date
from decimal import Decimal

from ccs_parser import totals as totals_mod
from ccs_parser.totals import TOTAL_KEYS, extract_totals

FAB_LINES = [
    "MR JOHN DOE Main Card Product Statement Date Payment Due Date",
    "SOME TOWER CASHBACK CARD 01-02-2026 26-02-2026",
    "Main Card Number Current Balance Minimum Payment Due",
    "SOME ADDRESS LINE",
    "1234 56** **** 9999 554.40CR 0.00",
    "Summary Details",
    "Previous Balance + Purchases/Debits + Cash Advances + Finance Charges - Payments/Credits Total Payment Due",
    "1,768.62 5,189.86 0.00 0.55 7,513.43 554.40CR",
    "Total Credit Limit Available Credit Limit",
    "www.example.com. VAT and T&Cs apply.",
    "30,000.00 28,133.06",
]

ENBD_LINES = [
    "Credit Limit Available Credit Limit (AED) Statement Date Payment Due Date Minimum Payment Due",
    "20000 16,785.06 28/11/2025 23/12/2025 100.00",
    "Previous Statement Purchase / Cash Interest/Other Payments/Credits (AED) Total Payment Due (AED) Current Balance (AED)",
    "Due (AED) Advance (AED) Charges (AED)",
    "-.55 7,767.49 0.00 9,346.00 0.00 -1,579.06",
]


def test_fab_totals() -> None:
    result = extract_totals("FAB", FAB_LINES)
    assert result.values == {
        "opening_balance": Decimal("1768.62"),
        "closing_balance": Decimal("-554.40"),
        "total_debits": Decimal("5190.41"),
        "total_credits": Decimal("7513.43"),
        "min_due": Decimal("0.00"),
        "credit_limit": Decimal("30000.00"),
    }
    assert result.warnings == []


def test_enbd_and_eib_totals() -> None:
    for bank in ("ENBD", "EIB"):
        result = extract_totals(bank, ENBD_LINES)
        assert result.values["credit_limit"] == Decimal("20000")
        assert result.values["min_due"] == Decimal("100.00")
        assert result.values["opening_balance"] == Decimal("-0.55")
        assert result.values["total_debits"] == Decimal("7767.49")
        assert result.values["total_credits"] == Decimal("9346.00")
        assert result.values["closing_balance"] == Decimal("-1579.06")
        assert result.due_date == date(2025, 12, 23)


def test_adcb_balance_lines() -> None:
    result = extract_totals("ADCB", ["PREVIOUS BALANCE OUTSTANDING 1,520.30", "NEW BALANCE OUTSTANDING 3,410.00"])
    assert result.values["opening_balance"] == Decimal("1520.30")
    assert result.values["closing_balance"] == Decimal("3410.00")


def test_unknown_layout_and_bank_give_all_null() -> None:
    for bank, lines in (("FAB", ["nothing here"]), ("MASHREQ", FAB_LINES), ("FAB", None), ("FAB", [])):
        result = extract_totals(bank, lines)
        assert set(result.values) == set(TOTAL_KEYS)
        assert all(v is None for v in result.values.values())


def test_totals_extraction_never_raises(monkeypatch) -> None:
    def _boom(lines, result):
        raise RuntimeError("layout exploded")

    monkeypatch.setitem(totals_mod._EXTRACTORS, "FAB", _boom)
    result = extract_totals("FAB", FAB_LINES)
    assert all(v is None for v in result.values.values())
    assert result.warnings and "RuntimeError" in result.warnings[0]
