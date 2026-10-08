from __future__ import annotations

from ccs_parser.domain.parsing.utils import classify_transaction_kind


def test_classify_transaction_kind_rewards_cashback_is_refund() -> None:
    kind = classify_transaction_kind("FAB REWARDS REDEMPTION - CASHBACK", 125.0)
    assert kind == "refund"


def test_classify_transaction_kind_negative_amount_is_payment() -> None:
    kind = classify_transaction_kind("RANDOM MERCHANT", -50.0)
    assert kind == "payment"
