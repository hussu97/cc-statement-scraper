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


# DP-10: the Payments/Credits column leaves out rewards redemptions and dispute credits.
FAB_OTHER_CREDIT_LINES = [
    "Main Card Number Current Balance Minimum Payment Due",
    "4000 12** **** 2468 1,000.00 100.00",
    "Previous Balance + Purchases/Debits + Cash Advances + Finance Charges - Payments/Credits Total Payment Due",
    "1,500.00 1,199.95 0.00 0.05 1,500.00 1,000.00",
]


def test_fab_total_credits_include_credits_outside_the_payments_column() -> None:
    result = extract_totals("FAB", FAB_OTHER_CREDIT_LINES)
    assert result.values["total_debits"] == Decimal("1200.00")
    # 1,500.00 payments + a 200.00 rewards redemption the column doesn't show.
    assert result.values["total_credits"] == Decimal("1700.00")
    assert result.values["closing_balance"] == Decimal("1000.00")


def test_fab_credit_balance_with_other_credits() -> None:
    lines = [
        "Main Card Number Current Balance Minimum Payment Due",
        "4000 12** **** 2468 1,850.00CR 0.00",
        "Previous Balance + Purchases/Debits + Cash Advances + Finance Charges - Payments/Credits Total Payment Due",
        "1,200.00 3,000.00 0.00 5.00 4,555.00 1,850.00CR",
    ]
    result = extract_totals("FAB", lines)
    assert result.values["closing_balance"] == Decimal("-1850.00")
    assert result.values["total_credits"] == Decimal("6055.00")


def test_fab_total_credits_untouched_when_the_row_disagrees_with_current_balance() -> None:
    lines = [*FAB_OTHER_CREDIT_LINES]
    lines[1] = "4000 12** **** 2468 1,100.00 100.00"
    result = extract_totals("FAB", lines)
    assert result.values["total_credits"] == Decimal("1500.00")


def test_fab_row_that_adds_up_is_unchanged() -> None:
    assert extract_totals("FAB", FAB_LINES).values["total_credits"] == Decimal("7513.43")


# DP-12: Mashreq "Summary AED" block (the Arabic labels extract as mojibake after the amount).
MASHREQ_LINES = [
    "Card No 4000 XXXX XXXX 1234 ¶zâlD",
    "Total outstanding balance 1,184.50 yPGZ",
    "Minimum payment due 59.23 ¶|PGZ",
    "-Enjoy cashback on purchases Statement date 06/02/2026 ÈâZP",
    "-No annual fee, FREE for Life! Payment due date 05/03/2026",
    "Summary AED dS¦©",
    "Previous balance 2,000.00 yCâZ",
    "- payments 2,000.00 ÊârwT -",
    "- other credits 100.00 ìVS -",
    "+ finance charges 0.00 ¤ƒ +",
    "+ other charges 0.00 ìVS +",
    "+ new transactions 1,284.50 ÉTTM +",
    "+ current balance 1,184.50 Œ¥âP +",
    "+ cash advance 0.00 ¶x +",
    "= outstanding balance 1,184.50 yPGZ =",
    "terms and conditions are subject to change. + Total deal instalments 0.00",
    "Combined credit limit 20,000.00 ßVGc",
    "Minimum Payment Due is the minimum payment required to be made",
]


def test_mashreq_summary() -> None:
    result = extract_totals("MASHREQ", MASHREQ_LINES)
    assert result.values == {
        "opening_balance": Decimal("2000.00"),
        "closing_balance": Decimal("1184.50"),
        "total_debits": Decimal("1284.50"),
        "total_credits": Decimal("2100.00"),
        "min_due": Decimal("59.23"),
        "credit_limit": Decimal("20000.00"),
    }
    assert result.due_date == date(2026, 3, 5)
    assert result.warnings == []


def test_mashreq_summary_that_does_not_add_up_is_left_null() -> None:
    lines = [ln.replace("+ new transactions 1,284.50", "+ new transactions 1,284.05") for ln in MASHREQ_LINES]
    result = extract_totals("MASHREQ", lines)
    assert result.values["opening_balance"] is None
    assert result.values["total_debits"] is None
    assert result.values["min_due"] == Decimal("59.23")
    assert result.warnings == ["MASHREQ: statement summary does not add up; balance totals left null"]


def test_mashreq_partial_summary_is_left_null() -> None:
    lines = [ln for ln in MASHREQ_LINES if not ln.startswith("+ cash advance")]
    result = extract_totals("MASHREQ", lines)
    assert result.values["closing_balance"] is None
    assert result.warnings == ["MASHREQ: statement summary incomplete; balance totals left null"]


def test_mashreq_credit_balance() -> None:
    lines = [
        ln.replace("+ current balance 1,184.50", "+ current balance 115.50CR").replace(
            "Previous balance 2,000.00", "Previous balance 700.00"
        )
        for ln in MASHREQ_LINES
    ]
    result = extract_totals("MASHREQ", lines)
    assert result.values["opening_balance"] == Decimal("700.00")
    assert result.values["closing_balance"] == Decimal("-115.50")


# Sep 2026 layout: Arabic labels interleaved (presentation forms), a credit closing balance.
WIO_LINES = [
    "CREDIT STATEMENT CURRENCY MONTHLY INTEREST RATE ANNUAL INTEREST RATE",
    "28/02/2026 ﻰﻟﺇ 28/01/2026 CREDIT LIMIT TOT. INTEREST AND FEES",
    "ﻲﻧﺎﻤﺘﺋﻻﺍ",
    "20,000.00 0.00",
    "PAYMENT DUE DATE MIN. PAYMENT DUE TOTAL TO PAY",
    "Jane Quincy ﺩﺍﺪﺴﻟﺍ",
    "Sample",
    "28/02/2026 30.00 0.00",
    "Balance from last statement 0.00",
    "Purchases +1,000.00",
    "Interest +0.00",
    "Late payment fee +0.00",
    "Foreign exchange charges +20.00",
    "Payments and credits -1,120.00",
    "Closing balance (Total to pay) -100.00",
]


def test_wio_summary() -> None:
    result = extract_totals("WIO", WIO_LINES)
    assert result.values == {
        "opening_balance": Decimal("0.00"),
        "closing_balance": Decimal("-100.00"),
        "total_debits": Decimal("1020.00"),
        "total_credits": Decimal("1120.00"),
        "min_due": Decimal("30.00"),
        "credit_limit": Decimal("20000.00"),
    }
    assert result.due_date == date(2026, 2, 28)
    assert result.warnings == []


def test_wio_summary_that_does_not_add_up_is_left_null() -> None:
    lines = [ln.replace("-100.00", "-90.00") for ln in WIO_LINES]
    result = extract_totals("WIO", lines)
    assert result.values["opening_balance"] is None and result.values["closing_balance"] is None
    assert result.values["credit_limit"] == Decimal("20000.00")
    assert result.warnings == ["WIO: account summary does not add up; balance totals left null"]
