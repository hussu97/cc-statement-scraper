from __future__ import annotations

from decimal import Decimal

import pytest

from ccs_parser.kinds import map_kind
from ccs_parser.service import fx_rate, money, money_or_none


@pytest.mark.parametrize(
    ("legacy", "description", "direction", "expected"),
    [
        ("purchase", "CARREFOUR DUBAI ARE", "debit", "purchase"),
        ("fee", "MEMBERSHIP FEE ASSESSED", "debit", "fee"),
        ("fee", "BILLED FINANCE CHARGES", "debit", "interest"),
        ("purchase", "INTEREST ON PURCHASES", "debit", "interest"),
        ("fee", "PROFIT CHARGE", "debit", "interest"),
        ("fee", "MURABAHA PROFIT", "debit", "interest"),
        ("fee", "VAT ON FINANCE CHARGE", "debit", "fee"),
        ("refund", "INTEREST REVERSAL", "credit", "refund"),
        ("refund", "WAKALA PROFIT", "credit", "refund"),
        ("payment", "PAYMENT RECEIVED - THANK YOU", "credit", "payment"),
        ("cash_advance", "CASH ADV ATM", "debit", "cash_advance"),
        ("something_new", "X", "debit", "adjustment"),
    ],
)
def test_map_kind(legacy: str, description: str, direction: str, expected: str) -> None:
    assert map_kind(legacy, description, direction) == expected


def test_money_is_absolute_two_place_string() -> None:
    assert money(-840.0) == "840.00"
    assert money(120.5) == "120.50"
    assert money(1234567.89) == "1234567.89"
    assert money(-0.05) == "0.05"
    assert money(Decimal("-1579.06")) == "1579.06"
    assert money_or_none(None) is None


def test_fx_rate_formatting() -> None:
    assert fx_rate(None) is None
    assert fx_rate(0.0) is None
    assert fx_rate(1.0) == "1"
    assert fx_rate(3.6725) == "3.6725"
    assert fx_rate(36.73 / 10.0) == "3.673"
    # Long ratios are rounded to 8 places.
    assert fx_rate(100.0 / 27.23) == "3.67242012"


def test_fx_rate_contract_nits() -> None:
    """X-33: AED is always "1"; a rate below numeric(18,8) precision is unknown, not "0"."""
    assert fx_rate(None, "AED") == "1"
    assert fx_rate(1.0, "AED") == "1"
    assert fx_rate(0.999, "AED") == "1"
    assert fx_rate(0.000000004, "VND") is None
    assert fx_rate(0.000000006, "VND") == "0.00000001"
    assert fx_rate(0.00014, "IDR") == "0.00014"
    assert fx_rate(None, "USD") is None


@pytest.mark.parametrize(
    ("merchant", "amount", "expected"),
    [
        ("ARTCAFFE COFFEE AND BA NAIROBI KEN", 25.0, "purchase"),
        ("THE COFFEE CLUB DUBAI ARE", 30.0, "purchase"),
        ("ANNUAL FEE", 300.0, "fee"),
        ("LATE PAYMENT FEE", 100.0, "fee"),
        ("MEMBERSHIP FEES", 100.0, "fee"),
        ("DU RECHARGE DUBAI", 50.0, "purchase"),
        ("ETISALAT RECHARGES", 50.0, "purchase"),
        ("VAT ON SERVICE CHARGES", 5.0, "fee"),
        ("FINANCE CHARGES", 12.0, "fee"),
        ("CASH ADV ATM DUBAI", 500.0, "cash_advance"),
        ("ATM WDL ENBD MALL OF EMIRATES", 500.0, "cash_advance"),
        ("CASH WITHDRAWAL KENYA", 500.0, "cash_advance"),
        ("ATMOSPHERE BURJ KHALIFA DUBAI", 500.0, "purchase"),
        ("ATM REVERSAL", -500.0, "refund"),
        ("CASH ADVANCE FEE", 150.0, "fee"),
        ("PAYMENT RECEIVED - THANK YOU", -1000.0, "payment"),
        ("AMAZON REFUND", -10.0, "refund"),
    ],
)
def test_classify_transaction_kind_whole_words(merchant: str, amount: float, expected: str) -> None:
    from ccs_parser.domain.parsing.utils import classify_transaction_kind

    assert classify_transaction_kind(merchant, amount) == expected


def test_finance_charges_maps_to_interest_in_contract() -> None:
    from ccs_parser.domain.parsing.utils import classify_transaction_kind

    legacy = classify_transaction_kind("FINANCE CHARGES", 12.0)
    assert map_kind(legacy, "FINANCE CHARGES", "debit") == "interest"


def _row(desc: str, kind: str, *, day: int = 24, card: str = "2777", direction: str = "debit"):
    from datetime import date

    from ccs_parser.domain.statements.types import ParsedLine

    return ParsedLine(
        line_no=0,
        transaction_date=date(2026, 9, day),
        transaction_time=None,
        posting_date=None,
        merchant_raw=desc,
        merchant_normalized=desc,
        amount_original=1.0,
        currency_original="AED",
        amount_aed=1.0,
        direction=direction,
        transaction_kind=kind,
        country_code=None,
        card_last4=card,
    )


def _paired(rows) -> list[str]:
    from ccs_parser.kinds import pair_cash_advances

    return pair_cash_advances(rows, [map_kind(r.transaction_kind, r.merchant_normalized, r.direction) for r in rows])


def test_cash_advance_fee_marks_the_withdrawal_before_it() -> None:
    # FAB 2026-09-24: an ATM abroad is printed as its bank's name; VAT sits between it and the fee.
    rows = [
        _row("CARREFOUR DUBAI ARE", "purchase"),
        _row("DTBKEN NAIROBI KEN", "purchase"),
        _row("VAT ON SERVICE CHARGES", "fee"),
        _row("CASH ADVANCE FEE", "fee"),
        _row("VAT ON SERVICE CHARGES", "fee"),
    ]
    assert _paired(rows) == ["purchase", "cash_advance", "fee", "fee", "fee"]


def test_cash_advance_fee_directly_after_withdrawal() -> None:
    # ADCB / ENBD: fee then "VAT ON CASH ADVANCE FEE", which is not an anchor of its own.
    rows = [
        _row("BANGKOK BANK PHUKET", "purchase"),
        _row("CASH ADVANCE FEE", "fee"),
        _row("VAT ON CASH ADVANCE FEE", "fee"),
        _row("KOR RA KANG PHUKET", "purchase"),
    ]
    assert _paired(rows) == ["cash_advance", "fee", "fee", "purchase"]


@pytest.mark.parametrize(
    "before",
    [
        _row("DTBKEN NAIROBI KEN", "purchase", day=23),  # another date
        _row("DTBKEN NAIROBI KEN", "purchase", card="1111"),  # another card
        _row("AMAZON REFUND", "refund", direction="credit"),  # not a debit purchase
    ],
)
def test_cash_advance_fee_needs_same_card_and_date(before) -> None:
    rows = [before, _row("CASH ADVANCE FEE", "fee")]
    assert _paired(rows)[0] == map_kind(before.transaction_kind, before.merchant_normalized, before.direction)


def test_cash_advance_fee_does_not_reach_past_another_purchase() -> None:
    rows = [
        _row("DTBKEN NAIROBI KEN", "purchase"),
        _row("JAVA HOUSE NAIROBI", "purchase"),
        _row("CASH ADVANCE FEE", "fee"),
    ]
    assert _paired(rows) == ["purchase", "cash_advance", "fee"]


def test_lines_out_pairs_cash_advances() -> None:
    from ccs_parser.service import _lines_out

    rows = [_row("DTBKEN NAIROBI KEN", "purchase"), _row("CASH ADVANCE FEE", "fee")]
    for i, row in enumerate(rows):
        row.line_no = i + 1
        row.fingerprint = str(i) * 64
    assert [line["kind"] for line in _lines_out(rows)] == ["cash_advance", "fee"]
