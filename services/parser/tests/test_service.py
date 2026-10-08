from __future__ import annotations

from datetime import date

import pytest

from ccs_parser import parser_adapter, service
from ccs_parser.contract import ParseResponse
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.totals import TOTAL_KEYS

from .conftest import make_result, make_tx


@pytest.fixture
def stub_parser(monkeypatch):
    def _install(result, *, detected="ENBD", text_lines=None):
        monkeypatch.setattr(parser_adapter, "parse_statement_for_bank", lambda *_a, **_k: result)
        monkeypatch.setattr(service, "detect_bank_code", lambda *_a, **_k: detected)
        monkeypatch.setattr(service, "read_text_lines", lambda *_a, **_k: text_lines)

    return _install


def test_response_matches_contract_with_abs_amounts_and_direction(pdf_file, stub_parser) -> None:
    txs = [
        make_tx(desc="CARREFOUR DUBAI ARE", amount_aed=52.25),
        make_tx(desc="PAYMENT RECEIVED THANK YOU", amount_aed=-1000.0, kind="payment"),
        make_tx(desc="AMAZON REFUND", amount_aed=-25.5, kind="refund"),
        make_tx(desc="BILLED FINANCE CHARGES", amount_aed=12.0, kind="fee"),
        make_tx(desc="NAMECHEAP PHOENIX", amount_aed=None, amount_original=11.48, currency="USD", fx=None),
        make_tx(desc="HOTEL PARIS", amount_aed=367.25, amount_original=100.0, currency="USD", fx=3.6725),
    ]
    stub_parser(make_result(txs))

    out = service.parse_document(pdf_file, filename="statement.pdf", settings={"ENBD_PDF_PASSWORD": None})
    ParseResponse.model_validate(out)

    assert out["contract_version"] == 1
    assert out["document_kind"] == "statement_pdf"
    st = out["statements"][0]
    assert st["kind"] == "statement"
    assert st["statement_date"] == "2026-01-28"
    assert st["reference_source"] == "fallback"
    assert st["statement_reference"] == "AUTO-ENBD-2026-01-28-1234"
    assert set(st["totals"]) == set(TOTAL_KEYS)
    assert "source_pdf" not in st["metadata"]

    lines = st["lines"]
    assert [ln["line_no"] for ln in lines] == [1, 2, 3, 4, 5, 6]
    assert [ln["direction"] for ln in lines] == ["debit", "credit", "credit", "debit", "debit", "debit"]
    assert [ln["kind"] for ln in lines] == ["purchase", "payment", "refund", "interest", "purchase", "purchase"]
    assert lines[1]["amount_original"] == "1000.00"
    assert lines[1]["amount_aed"] == "1000.00"
    assert lines[2]["amount_aed"] == "25.50"
    assert lines[4]["amount_aed"] is None
    assert lines[4]["amount_original"] == "11.48"
    assert lines[4]["fx_rate"] is None
    assert lines[5]["fx_rate"] == "3.6725"
    assert lines[0]["legacy_fingerprint"] == txs[0].fingerprint
    for ln in lines:
        assert not ln["amount_original"].startswith("-")


def test_direction_falls_back_to_amount_original_when_no_aed(pdf_file, stub_parser) -> None:
    # SIB history foreign credit: amount_aed is None, sign lives on amount_original.
    tx = make_tx(desc="FOREIGN REFUND", amount_aed=None, amount_original=-20.0, currency="USD", kind="refund", fx=None)
    stub_parser(make_result([tx]))
    line = service.parse_document(pdf_file)["statements"][0]["lines"][0]
    assert line["direction"] == "credit"
    assert line["amount_original"] == "20.00"


def test_unknown_card_sentinel_becomes_null(pdf_file, stub_parser) -> None:
    stub_parser(
        make_result(
            [make_tx(desc="X SHOP", amount_aed=1.0, last4="0000")],
            metadata={"statement_date": "2026-01-28", "card_last4": "0000"},
        )
    )
    st = service.parse_document(pdf_file)["statements"][0]
    assert st["primary_card_last4"] is None
    assert st["lines"][0]["card_last4"] is None


def test_history_pdf_kinds(pdf_file, stub_parser) -> None:
    meta = {"statement_date": "2026-03-12", "pdf_type": "transaction_history", "card_last4": "9218"}
    results = [
        make_result([make_tx(desc="SHOP A", amount_aed=5.0)], bank_code="SIB", metadata=meta),
        make_result(
            [make_tx(desc="SHOP B", amount_aed=6.0)], bank_code="SIB", metadata={**meta, "statement_date": "2026-04-12"}
        ),
    ]
    stub_parser(results, detected="SIB", text_lines=["PREVIOUS BALANCE OUTSTANDING 1.00"])
    out = service.parse_document(pdf_file)
    assert out["document_kind"] == "history_pdf"
    assert [s["kind"] for s in out["statements"]] == ["history_extract", "history_extract"]
    assert all(v is None for s in out["statements"] for v in s["totals"].values())


def test_balances_are_signed_other_totals_absolute(pdf_file, stub_parser) -> None:
    lines = [
        "Previous Statement Purchase / Cash Interest/Other Payments/Credits (AED) Total Payment Due (AED) Current Balance (AED)",
        "-.55 7,767.49 0.00 9,346.00 0.00 -1,579.06",
    ]
    stub_parser(make_result([make_tx(desc="X SHOP", amount_aed=1.0)]), text_lines=lines)
    st = service.parse_document(pdf_file)["statements"][0]
    assert st["totals"]["closing_balance"] == "-1579.06"
    assert st["totals"]["opening_balance"] == "-0.55"
    assert st["totals"]["total_debits"] == "7767.49"
    assert st["totals"]["total_credits"] == "9346.00"
    assert "totals_negative" not in st["metadata"]


def test_signed_money_formatting() -> None:
    from decimal import Decimal

    assert service.signed_money(Decimal("-1579.06")) == "-1579.06"
    assert service.signed_money(Decimal("220.66")) == "220.66"
    assert service.signed_money(Decimal("-0.00")) == "0.00"
    assert service.signed_money(Decimal("-.55")) == "-0.55"


def test_contract_rejects_negative_non_balance_totals() -> None:
    import pytest as _pytest
    from pydantic import ValidationError

    from ccs_parser.contract import Totals

    base = dict.fromkeys(TOTAL_KEYS)
    Totals.model_validate({**base, "opening_balance": "-1.00", "closing_balance": "-2.50"})
    with _pytest.raises(ValidationError):
        Totals.model_validate({**base, "min_due": "-1.00"})


def test_statement_date_never_falls_back_to_today(pdf_file, stub_parser) -> None:
    # No metadata date, no transactions, legacy "1970-01" sentinel month.
    stub_parser(make_result([], metadata={"statement_date": None}, statement_month="1970-01"))
    with pytest.raises(ParserError) as exc:
        service.parse_document(pdf_file)
    assert exc.value.code == "UNSUPPORTED_LAYOUT"


def test_statement_date_falls_back_to_max_posting_date(pdf_file, stub_parser) -> None:
    txs = [
        make_tx(desc="A", amount_aed=1.0, posting=date(2026, 1, 3)),
        make_tx(desc="B", amount_aed=1.0, posting=date(2026, 1, 9)),
    ]
    stub_parser(make_result(txs, metadata={}))
    assert service.parse_document(pdf_file)["statements"][0]["statement_date"] == "2026-01-09"


def test_unsupported_bank_hint(pdf_file) -> None:
    with pytest.raises(ParserError) as exc:
        service.parse_document(pdf_file, bank_code_hint="HSBC")
    assert exc.value.code == "UNSUPPORTED_BANK"


def test_undetected_bank(pdf_file, monkeypatch) -> None:
    monkeypatch.setattr(service, "detect_bank_code", lambda *_a, **_k: None)
    monkeypatch.setattr(service, "pdf_open_state", lambda *_a, **_k: "ok")
    with pytest.raises(ParserError) as exc:
        service.parse_document(pdf_file)
    assert exc.value.code == "BANK_UNDETECTED"


def test_undetected_encrypted_pdf_is_decrypt_failure(pdf_file, monkeypatch) -> None:
    monkeypatch.setattr(service, "detect_bank_code", lambda *_a, **_k: None)
    monkeypatch.setattr(service, "pdf_open_state", lambda *_a, **_k: "encrypted")
    with pytest.raises(ParserError) as exc:
        service.parse_document(pdf_file)
    assert exc.value.code == "PDF_DECRYPT_FAILED"


def test_corrupt_pdf_with_hint_is_unsupported_layout(tmp_path) -> None:
    bad = tmp_path / "bad.pdf"
    bad.write_bytes(b"not a pdf at all")
    with pytest.raises(ParserError) as exc:
        service.parse_document(bad, bank_code_hint="MASHREQ")
    assert exc.value.code == "UNSUPPORTED_LAYOUT"


# ---------------------------------------------------------------- SRV-17: wrong bank hint


@pytest.fixture
def per_bank(monkeypatch):
    """Install a per-bank parser outcome (a result or a ParserError) and a detection result."""

    def _install(outcomes: dict, *, detected: str | None):
        calls: list[str] = []

        def parse(bank_code, *_a, **_k):
            calls.append(bank_code)
            outcome = outcomes[bank_code]
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        monkeypatch.setattr(parser_adapter, "parse_statement_for_bank", parse)
        monkeypatch.setattr(service, "detect_bank_code", lambda *_a, **_k: detected)
        monkeypatch.setattr(service, "read_text_lines", lambda *_a, **_k: None)
        return calls

    return _install


def _fab_result():
    return make_result([make_tx(desc="CORNER SHOP DUBAI ARE", amount_aed=10.0)], bank_code="FAB")


@pytest.mark.parametrize("code", ["UNSUPPORTED_LAYOUT", "PDF_DECRYPT_FAILED", "PARSE_OUTPUT_INVALID"])
def test_wrong_hint_is_retried_as_the_detected_bank(pdf_file, per_bank, code) -> None:
    calls = per_bank({"ADCB": ParserError(code, "no"), "FAB": _fab_result()}, detected="FAB")
    out = service.parse_document(pdf_file, bank_code_hint="ADCB")
    assert calls == ["ADCB", "FAB"]
    assert out["bank_code"] == "FAB"
    assert out["statements"][0]["warnings"][0] == (
        "Bank hint ADCB did not match this PDF; parsed as FAB (detected from the PDF)"
    )
    ParseResponse.model_validate(out)


def test_hint_with_no_lines_is_retried(pdf_file, per_bank) -> None:
    empty = make_result([], bank_code="MASHREQ")
    calls = per_bank({"MASHREQ": empty, "FAB": _fab_result()}, detected="FAB")
    out = service.parse_document(pdf_file, bank_code_hint="MASHREQ")
    assert calls == ["MASHREQ", "FAB"]
    assert out["bank_code"] == "FAB"


def test_empty_hinted_result_stands_when_the_retry_finds_nothing_either(pdf_file, per_bank) -> None:
    calls = per_bank(
        {"MASHREQ": make_result([], bank_code="MASHREQ"), "FAB": ParserError("UNSUPPORTED_LAYOUT", "no")},
        detected="FAB",
    )
    out = service.parse_document(pdf_file, bank_code_hint="MASHREQ")
    assert calls == ["MASHREQ", "FAB"]
    assert out["bank_code"] == "MASHREQ"
    assert out["statements"][0]["lines"] == []


@pytest.mark.parametrize("detected", [None, "ADCB", "HSBC"])
def test_hint_error_stands_without_a_different_detection(pdf_file, per_bank, detected) -> None:
    calls = per_bank({"ADCB": ParserError("UNSUPPORTED_LAYOUT", "layout")}, detected=detected)
    with pytest.raises(ParserError) as exc:
        service.parse_document(pdf_file, bank_code_hint="ADCB")
    assert exc.value.code == "UNSUPPORTED_LAYOUT"
    assert calls == ["ADCB"]


def test_failed_retry_raises_the_hinted_error(pdf_file, per_bank) -> None:
    calls = per_bank(
        {"ADCB": ParserError("PDF_DECRYPT_FAILED", "hinted"), "FAB": ParserError("UNSUPPORTED_LAYOUT", "retry")},
        detected="FAB",
    )
    with pytest.raises(ParserError) as exc:
        service.parse_document(pdf_file, bank_code_hint="ADCB")
    assert (exc.value.code, str(exc.value)) == ("PDF_DECRYPT_FAILED", "hinted")
    assert calls == ["ADCB", "FAB"]


def test_hinted_parse_with_lines_stands_with_a_warning(pdf_file, per_bank) -> None:
    calls = per_bank({"MASHREQ": _fab_result()}, detected="ENBD")
    out = service.parse_document(pdf_file, bank_code_hint="MASHREQ")
    assert calls == ["MASHREQ"]
    assert out["bank_code"] == "MASHREQ"
    assert out["statements"][0]["warnings"][0] == (
        "This PDF looks like ENBD, not MASHREQ; parsed as MASHREQ because of the bank hint"
    )


def test_matching_hint_has_no_warning(pdf_file, per_bank) -> None:
    per_bank({"FAB": _fab_result()}, detected="FAB")
    out = service.parse_document(pdf_file, bank_code_hint="FAB")
    assert not any("hint" in w for w in out["statements"][0]["warnings"])


def test_other_parser_errors_are_not_retried(pdf_file, per_bank) -> None:
    calls = per_bank({"ADCB": ParserError("PDF_TOO_LARGE", "big")}, detected="FAB")
    with pytest.raises(ParserError) as exc:
        service.parse_document(pdf_file, bank_code_hint="ADCB")
    assert exc.value.code == "PDF_TOO_LARGE"
    assert calls == ["ADCB"]


# ---------------------------------------------------------------- X-25r / X-33 output normalisation


def test_country_codes_and_aed_rates_are_normalised(pdf_file, stub_parser) -> None:
    txs = [
        make_tx(desc="SHOP DUBAI ARE", amount_aed=10.0, fx=None),
        make_tx(desc="SHOP DXB", amount_aed=10.0),
        make_tx(desc="PAYMENT THANK YOU", amount_aed=-10.0, kind="payment"),
        make_tx(desc="HOTEL DUBLIN IRL", amount_aed=36.73, amount_original=10.0, currency="EUR", fx=3.673),
    ]
    for tx, raw in zip(txs, ["ARE", "DXB", "YOU", "IRL"], strict=True):
        tx.country_code = raw
    stub_parser(make_result(txs))
    lines = service.parse_document(pdf_file)["statements"][0]["lines"]
    assert [ln["country_code"] for ln in lines] == ["AE", "AE", None, "IE"]
    assert [ln["fx_rate"] for ln in lines] == ["1", "1", "1", "3.673"]
