from __future__ import annotations

from pathlib import Path

import pytest

from ccs_parser.banks.sib import parse_sib_statement, parse_sib_transaction_history
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
                    "HUSSAIN FAHIM AKHTER ABBASI",
                    "Date range 20/02/2026 To 07/06/2026",
                    "Account no. 5290 xxxx xxxx 6774",
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
