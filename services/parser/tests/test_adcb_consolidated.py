"""ADCB consolidated statement of accounts: bank accounts, their lines and deposits (tasks/todo.md §9)."""

from __future__ import annotations

import copy
from pathlib import Path

import pytest
from pydantic import ValidationError

from ccs_parser.banks.adcb_consolidated import account_kind, classify, description_shape
from ccs_parser.contract import ParseResponse
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.service import parse_document
from tests.synthetic.cases import _ADCB_CONSOLIDATED_PAGES, CASES, PASSWORD
from tests.synthetic_pdf import write_pdf


@pytest.fixture(autouse=True)
def _inline(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PARSER_ISOLATION", "inline")


def _parse(tmp_path: Path, pages: list, **settings: str) -> dict:
    pdf = write_pdf(tmp_path / "consolidated.pdf", pages, password=PASSWORD)
    return parse_document(pdf, bank_code_hint="ADCB", settings=settings or {"ADCB_CID": PASSWORD})


@pytest.mark.parametrize(
    ("description", "direction", "kind", "merchant", "card"),
    [
        ("PUR 11/09 GOOGLE*YOU MOUNTAIN VIEW 9211", "debit", "purchase", "GOOGLE*YOU MOUNTAIN VIEW", "9211"),
        ("PUR 11/09 SAMPLE MART 9211", "credit", "refund", "SAMPLE MART", "9211"),
        ("FOREIGN TRANSACTION FEE 11/09 0 784 GOOGLE*YOU9211", "debit", "fee", "FOREIGN TRANSACTION FEE", "9211"),
        ("SERVICE CHARGES", "debit", "fee", "SERVICE CHARGES", None),
        ("PROFIT CREDIT", "credit", "interest", "PROFIT CREDIT", None),
        ("IPP TRANSFER TO J SAMPLE", "debit", "transfer_out", "IPP TRANSFER TO J SAMPLE", None),
        ("INWARD REMITTANCE", "credit", "transfer_in", "INWARD REMITTANCE", None),
    ],
)
def test_classify(description: str, direction: str, kind: str, merchant: str, card: str | None) -> None:
    cl = classify(description, direction)
    assert (cl.kind, cl.merchant, cl.card_last4) == (kind, merchant, card)
    assert cl.known == (kind not in ("transfer_in", "transfer_out"))


def test_description_shape_hides_names_and_numbers() -> None:
    shape = description_shape("IPP TRANSFER TO JOHN SMITH 12/09 AE070331234567890123456")
    assert shape == "IPP w w w w # w"
    assert "JOHN" not in shape and "SMITH" not in shape
    # A first word that isn't a transaction code (too long, or a number) is masked too.
    assert description_shape("MOHAMMEDABDULLAH SALARY") == "w w"
    assert description_shape("1234 TRANSFER") == "# w"


def test_account_kind() -> None:
    assert account_kind("Islamic Active Saver Account") == "savings"
    assert account_kind("Islamic Current Account Personal") == "current"
    assert account_kind("Call Account") == "savings"


def test_reads_accounts_lines_deposits_and_cards(tmp_path: Path) -> None:
    out = _parse(tmp_path, _ADCB_CONSOLIDATED_PAGES)
    assert out["document_kind"] == "account_statement_pdf"
    saver, current = out["statements"]
    assert saver["account"] == {
        "kind": "savings",
        "number": "99990001310001",
        "ref": "310001",
        "iban": "AE000030099990001310001",
        "product": "Islamic Active Saver Account",
        "currency": "AED",
    }
    assert (saver["totals"]["opening_balance"], saver["totals"]["closing_balance"]) == ("1000.00", "1012.40")
    assert current["account"]["kind"] == "current"
    assert (current["totals"]["opening_balance"], current["totals"]["closing_balance"]) == ("5000.00", "4161.92")
    assert (current["totals"]["total_debits"], current["totals"]["total_credits"]) == ("1338.08", "500.00")
    # Wrapped descriptions join in reading order; the value date is the transaction date.
    purchase = current["lines"][0]
    assert purchase["description_raw"] == "PUR 10/09 SAMPLE MART DUBAI 5678"
    assert (purchase["txn_date"], purchase["posting_date"], purchase["card_last4"]) == (
        "2026-09-10",
        "2026-09-12",
        "5678",
    )
    # Page 3 continues the table without a header.
    assert [ln["kind"] for ln in current["lines"]] == ["purchase", "fee", "transfer_out", "transfer_in", "fee"]
    assert current["metadata"]["unrecognised_lines"] == [
        {"line_no": 3, "direction": "debit", "shape": "IPP w w w w #"},
        {"line_no": 4, "direction": "credit", "shape": "INWARD w w w"},
    ]
    assert out["deposits"] == [
        {
            "number": "99990001340001",
            "product": "ADCB Online Century Deposit",
            "currency": "AED",
            "rate_pct": "2.00",
            "maturity_on": "2027-04-01",
            "amount": "52301.10",
            "as_of": "2026-09-30",
        }
    ]
    assert [c["last4"] for c in out["card_summaries"]] == ["1234"]
    assert out["card_summaries"][0]["credit_limit"] == "10000.00"


def test_a_running_balance_break_fails_the_parse(tmp_path: Path) -> None:
    pages = copy.deepcopy(_ADCB_CONSOLIDATED_PAGES)
    row = next(line for line in pages[1] if isinstance(line, list) and (255, "200001") in line)
    row[row.index((545, "4,914.50"))] = (545, "4,914.05")
    with pytest.raises(ParserError) as err:
        _parse(tmp_path, pages)
    assert err.value.code == "UNSUPPORTED_LAYOUT"
    assert "running balance" in err.value.message


def test_the_customer_id_opens_it_even_beside_a_card_password(tmp_path: Path) -> None:
    out = _parse(tmp_path, _ADCB_CONSOLIDATED_PAGES, ADCB_PDF_PASSWORD="card-password", ADCB_CID=PASSWORD)
    assert out["document_kind"] == "account_statement_pdf"
    with pytest.raises(ParserError) as err:
        _parse(tmp_path, _ADCB_CONSOLIDATED_PAGES, ADCB_PDF_PASSWORD="card-password", ADCB_CID="wrong")
    assert err.value.code == "PDF_DECRYPT_FAILED"


def test_a_card_statement_opens_with_either_adcb_password(tmp_path: Path) -> None:
    case = CASES["adcb_encrypted"]
    pdf = case.write(tmp_path / "card.pdf")
    out = parse_document(pdf, bank_code_hint="ADCB", settings={"ADCB_PDF_PASSWORD": "wrong", "ADCB_CID": PASSWORD})
    assert out["document_kind"] == "statement_pdf"
    assert "account" not in out["statements"][0] and "deposits" not in out


def test_detected_without_a_hint(tmp_path: Path) -> None:
    pdf = write_pdf(tmp_path / "consolidated.pdf", _ADCB_CONSOLIDATED_PAGES, password=PASSWORD)
    out = parse_document(pdf, settings={"ADCB_CID": PASSWORD})
    assert out["bank_code"] == "ADCB" and out["document_kind"] == "account_statement_pdf"


def test_contract_ties_accounts_to_the_document_kind(tmp_path: Path) -> None:
    out = _parse(tmp_path, _ADCB_CONSOLIDATED_PAGES)
    ParseResponse.model_validate(out)
    card_kind = {**out, "document_kind": "statement_pdf"}
    with pytest.raises(ValidationError):
        ParseResponse.model_validate(card_kind)
    no_account = copy.deepcopy(out)
    no_account["statements"][0]["account"] = None
    with pytest.raises(ValidationError):
        ParseResponse.model_validate(no_account)
