from __future__ import annotations

from pathlib import Path

import pytest

from ccs_parser.banks.sib import _masked_card_last4, parse_sib_statement, parse_sib_transaction_history
from ccs_parser.domain.parsing.models import ParserError


def test_sib_missing_password_raises_pdf_decrypt_failed() -> None:
    with pytest.raises(ParserError) as exc:
        parse_sib_statement(Path("dummy-sib.pdf"), "")
    assert exc.value.code == "PDF_DECRYPT_FAILED"


def test_sib_unknown_layout_raises_explicit_error(monkeypatch: pytest.MonkeyPatch) -> None:
    class _FakePage:
        def extract_text(self) -> str:
            return "This PDF has no tabular transactions"

    class _FakePdf:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb) -> None:
            return None

        @property
        def pages(self):
            return [_FakePage()]

    monkeypatch.setattr(
        "ccs_parser.banks.sib.pdfplumber.open",
        lambda *_args, **_kwargs: _FakePdf(),
    )

    with pytest.raises(ParserError) as exc:
        parse_sib_statement(Path("dummy-sib.pdf"), "dummy-password")
    assert exc.value.code == "UNSUPPORTED_LAYOUT"


def test_sib_transaction_history_normalizes_source_signs(monkeypatch: pytest.MonkeyPatch) -> None:
    class _FakePage:
        def extract_text(self) -> str:
            return "\n".join(
                [
                    "Transaction history",
                    "JOHN QUINCY PUBLIC SAMPLE",
                    "Date range 20/02/2026 To 07/06/2026",
                    "Account no. 5290 xxxx xxxx 9218",
                    "Account type SIB MC CASHBACK",
                    "Currency AED",
                    "Date Details Amount",
                    "05 Jun 2026 MELTINGMOMENTSCAKESSHARJAH AED -5.00",
                    "16 May 2026 Credit Card Payment AED 49.00",
                    "17 Apr 2026 CASHBACK REDEEMED AED 302.00",
                    "14 Apr 2026 MURABAHA PROFIT AED -348.90",
                    "05 Mar 2026 NAME CHEAP.COM CE6IN2PHOENIX USD -11.48",
                ]
            )

    class _FakePdf:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb) -> None:
            return None

        @property
        def pages(self):
            return [_FakePage()]

    monkeypatch.setattr(
        "ccs_parser.banks.sib.pdfplumber.open",
        lambda *_args, **_kwargs: _FakePdf(),
    )

    results = parse_sib_transaction_history(Path("dummy-sib-history.pdf"))
    txns = {tx.merchant_raw: tx for result in results for tx in result.transactions}

    spend = txns["MELTINGMOMENTSCAKESSHARJAH"]
    assert spend.amount_original == 5.0
    assert spend.amount_aed == 5.0
    assert spend.transaction_kind == "purchase"

    payment = txns["Credit Card Payment"]
    assert payment.amount_original == -49.0
    assert payment.amount_aed == -49.0
    assert payment.transaction_kind == "payment"

    cashback = txns["CASHBACK REDEEMED"]
    assert cashback.amount_original == -302.0
    assert cashback.amount_aed == -302.0
    assert cashback.transaction_kind == "refund"

    fee = txns["MURABAHA PROFIT"]
    assert fee.amount_original == 348.9
    assert fee.amount_aed == 348.9
    assert fee.transaction_kind == "fee"

    foreign_spend = txns["NAME CHEAP.COM CE6IN2PHOENIX"]
    assert foreign_spend.amount_original == 11.48
    assert foreign_spend.amount_aed is None
    assert foreign_spend.transaction_kind == "purchase"


def _fake_pdf(monkeypatch: pytest.MonkeyPatch, text: str) -> None:
    class _FakePage:
        def extract_text(self) -> str:
            return text

    class _FakePdf:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb) -> None:
            return None

        @property
        def pages(self):
            return [_FakePage()]

    monkeypatch.setattr("ccs_parser.banks.sib.pdfplumber.open", lambda *_args, **_kwargs: _FakePdf())


def test_masked_card_last4_accepts_any_masking() -> None:
    assert _masked_card_last4("5290 xxxx xxxx 9218") == "9218"
    assert _masked_card_last4("5290 XXXX XXXX 4821") == "4821"
    assert _masked_card_last4("Card No: 5290********4821") == "4821"
    assert _masked_card_last4("xxxx xxxx xxxx 4821") == "4821"
    assert _masked_card_last4("529012** **** 4821") == "4821"
    assert _masked_card_last4("Account type SIB MC CASHBACK") is None
    assert _masked_card_last4("12 Mar 2026 SHOP 1234 AED -5.00") is None


def test_sib_history_of_a_replacement_card_reads_the_new_number(monkeypatch: pytest.MonkeyPatch) -> None:
    """The re-issued card's export has the same layout with a new number: every row and every
    billing cycle carries the new last4, so the DB can attach it to the same account."""
    _fake_pdf(
        monkeypatch,
        "\n".join(
            [
                "Transaction history",
                "JANE Q SAMPLE",
                "Date range 01/08/2026 To 30/09/2026",
                "Card no.: 5290 XXXX XXXX 4821",
                "Account type SIB MC CASHBACK",
                "Currency AED",
                "Date Details Amount",
                "20 Aug 2026 CORNER GROCERY SHARJAH AED -150.00",
                "14 Sep 2026 BOOK SHOP DUBAI AED -45.50",
            ]
        ),
    )
    results = parse_sib_transaction_history(Path("dummy-sib-history.pdf"))
    assert [r.metadata["card_last4"] for r in results] == ["4821", "4821"]
    assert {tx.card_last4 for r in results for tx in r.transactions} == {"4821"}
    assert results[0].metadata["card_type"] == "SIB MC CASHBACK"


def test_sib_history_with_two_card_sections_keeps_each_row_on_its_card(monkeypatch: pytest.MonkeyPatch) -> None:
    _fake_pdf(
        monkeypatch,
        "\n".join(
            [
                "Transaction history",
                "JANE Q SAMPLE",
                "Date range 01/07/2026 To 30/08/2026",
                "Account no. 5290 xxxx xxxx 9218",
                "Account type SIB MC CASHBACK",
                "Currency AED",
                "Date Details Amount",
                "05 Aug 2026 OLD CARD SHOP SHARJAH AED -10.00",
                "Account no. 5290 xxxx xxxx 4821",
                "Date Details Amount",
                "08 Aug 2026 NEW CARD SHOP SHARJAH AED -20.00",
                "10 Aug 2026 NEW CARD CAFE SHARJAH AED -30.00",
            ]
        ),
    )
    results = parse_sib_transaction_history(Path("dummy-sib-history.pdf"))
    cards = {tx.merchant_raw: tx.card_last4 for r in results for tx in r.transactions}
    assert cards == {
        "OLD CARD SHOP SHARJAH": "9218",
        "NEW CARD SHOP SHARJAH": "4821",
        "NEW CARD CAFE SHARJAH": "4821",
    }
    # One billing cycle (12 Aug); its primary card is the one with most rows: the new card.
    assert [r.metadata["card_last4"] for r in results] == ["4821"]


def test_sib_statement_reads_a_lowercase_masked_card(monkeypatch: pytest.MonkeyPatch) -> None:
    _fake_pdf(
        monkeypatch,
        "\n".join(
            [
                "Card Number 5290 xxxx xxxx 4821",
                "Statement Period: 13/08/2026 to 12/09/2026",
                "20/08/2026 21/08/2026 CORNER GROCERY SHARJAH 150.00",
            ]
        ),
    )
    result = parse_sib_statement(Path("dummy-sib.pdf"), "pw")
    assert result.metadata["card_last4"] == "4821"
    assert result.transactions[0].card_last4 == "4821"
