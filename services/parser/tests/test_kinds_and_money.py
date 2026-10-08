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
