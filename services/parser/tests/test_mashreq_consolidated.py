"""Mashreq NEO consolidated relationship statement: current and savings accounts and their lines."""

from __future__ import annotations

import copy
from pathlib import Path

import pytest

from ccs_parser.banks.mashreq_consolidated import classify
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.service import parse_document
from tests.synthetic.cases import _MASHREQ_CONSOLIDATED_PAGES, CASES, PASSWORD
from tests.synthetic_pdf import write_pdf


@pytest.fixture(autouse=True)
def _inline(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PARSER_ISOLATION", "inline")


def _parse(tmp_path: Path, pages: list, hint: str | None = "MASHREQ", **settings: str) -> dict:
    pdf = write_pdf(tmp_path / "consolidated.pdf", pages, password=PASSWORD)
    return parse_document(pdf, bank_code_hint=hint, settings=settings or {"MASHREQ_PDF_PASSWORD": PASSWORD})


@pytest.mark.parametrize(
    ("description", "direction", "kind", "merchant", "known"),
    [
        (
            "Account to Account Transfer FROM ACCOUNT No:1 TO ACCOUNT No: 2",
            "debit",
            "transfer_out",
            "ACCOUNT TO ACCOUNT TRANSFER",
            True,
        ),
        (
            "Account to Account Transfer FROM ACCOUNT No:1 TO ACCOUNT No: 2",
            "credit",
            "transfer_in",
            "ACCOUNT TO ACCOUNT TRANSFER",
            True,
        ),
        (
            "IPP TRANSFER 0190AE00 - J SAMPLE - /REF/ Family Support - T_0",
            "debit",
            "transfer_out",
            "IPP TRANSFER",
            True,
        ),
        # A row booked on another day than its value date carries the value date first.
        (
            "VALUE DATE: 31-05-2026 Account to Account Transfer FROM ACCOUNT No:1 TO ACCOUNT No: 2",
            "debit",
            "transfer_out",
            "ACCOUNT TO ACCOUNT TRANSFER",
            True,
        ),
        ("VALUE DATE: 31-05-2026 IPP TRANSFER 0190AE00 - J SAMPLE", "debit", "transfer_out", "IPP TRANSFER", True),
        ("Inward Remittance J SAMPLE SAMPLE BANK P.J.S.C.", "credit", "transfer_in", "INWARD REMITTANCE", True),
        ("OUTWARD REMITTANCE J SAMPLE", "debit", "transfer_out", "OUTWARD REMITTANCE", True),
        ("VALUE DATE: 01-10-2026 Interest 099990002222", "credit", "interest", "INTEREST", True),
        ("SERVICE CHARGES", "debit", "fee", "SERVICE CHARGES", True),
        ("POS PURCHASE SAMPLE MART", "debit", "transfer_out", "POS PURCHASE SAMPLE MART", False),
        ("SALARY SAMPLE CO", "credit", "transfer_in", "SALARY SAMPLE CO", False),
    ],
)
def test_classify(description: str, direction: str, kind: str, merchant: str, known: bool) -> None:
    cl = classify(description, direction)
    assert (cl.kind, cl.merchant, cl.known) == (kind, merchant, known)


def test_reads_both_accounts_and_their_lines(tmp_path: Path) -> None:
    out = _parse(tmp_path, _MASHREQ_CONSOLIDATED_PAGES)
    assert (out["bank_code"], out["document_kind"]) == ("MASHREQ", "account_statement_pdf")
    assert "deposits" not in out and "card_summaries" not in out
    saver, current = out["statements"]
    assert saver["account"] == {
        "kind": "savings",
        "number": "099990002222",
        "ref": "2222",
        "iban": "AE000330000099990002222",
        "product": "Neo Plus Saver - Balance",
        "currency": "AED",
    }
    assert (saver["period_start"], saver["period_end"], saver["card_holder"]) == (
        "2026-09-01",
        "2026-09-30",
        "JANE Q SAMPLE",
    )
    # Three-decimal amounts become money; the narration row joins the transfer above it.
    assert (saver["totals"]["opening_balance"], saver["totals"]["closing_balance"]) == ("15000.00", "10041.66")
    transfer, interest = saver["lines"]
    assert transfer["description_raw"] == (
        "Account to Account Transfer FROM ACCOUNT No:099990002222 TO ACCOUNT No: 099990001111"
    )
    assert (transfer["kind"], transfer["amount_original"]) == ("transfer_out", "5000.00")
    assert (interest["kind"], interest["direction"], interest["txn_date"]) == ("interest", "credit", "2026-09-30")

    # The wrapped product name; a cell centred on its row; the table continues on page 4.
    assert current["account"]["product"] == "Neo Current Account"
    assert [ln["kind"] for ln in current["lines"]] == ["transfer_in", "transfer_out", "transfer_out", "fee"]
    assert current["lines"][1]["description_raw"] == (
        "IPP TRANSFER 019030000000AE000860000009999999999 - JANE Q SAMPLE - /REF/ Family Support - "
        "T_00000000000000000000000000000001"
    )
    assert current["totals"] == {
        "opening_balance": "0.01",
        "closing_balance": "4000.01",
        "total_debits": "1000.00",
        "total_credits": "5000.00",
        "min_due": None,
        "credit_limit": None,
    }
    assert current["metadata"]["unrecognised_lines"] == [{"line_no": 3, "direction": "debit", "shape": "POS w w w #"}]


def test_detected_without_a_hint(tmp_path: Path) -> None:
    out = _parse(tmp_path, _MASHREQ_CONSOLIDATED_PAGES, hint=None)
    assert (out["bank_code"], out["document_kind"]) == ("MASHREQ", "account_statement_pdf")


def test_a_wrong_password_fails_to_decrypt(tmp_path: Path) -> None:
    with pytest.raises(ParserError) as err:
        _parse(tmp_path, _MASHREQ_CONSOLIDATED_PAGES, MASHREQ_PDF_PASSWORD="wrong")
    assert err.value.code == "PDF_DECRYPT_FAILED"


def _replace(pages: list, old: str, new: str) -> list:
    pages = copy.deepcopy(pages)
    for page in pages:
        for line in page:
            if isinstance(line, list):
                for i, (x, text) in enumerate(line):
                    if text == old:
                        line[i] = (x + len(old) - len(new), new)
                        return pages
    raise AssertionError(old)


def test_a_running_balance_break_fails_the_parse(tmp_path: Path) -> None:
    with pytest.raises(ParserError) as err:
        _parse(tmp_path, _replace(_MASHREQ_CONSOLIDATED_PAGES, "4,250.010", "4,205.010"))
    assert err.value.code == "UNSUPPORTED_LAYOUT"
    assert "running balance" in err.value.message


def test_a_closing_balance_that_does_not_follow_fails_the_parse(tmp_path: Path) -> None:
    pages = copy.deepcopy(_MASHREQ_CONSOLIDATED_PAGES)
    closing = pages[1][-2]
    closing[-1] = (closing[-1][0], "10,041.600")
    with pytest.raises(ParserError) as err:
        _parse(tmp_path, pages)
    assert "closing balance" in err.value.message


def test_an_amount_below_a_fils_fails_the_parse(tmp_path: Path) -> None:
    with pytest.raises(ParserError) as err:
        _parse(tmp_path, _replace(_MASHREQ_CONSOLIDATED_PAGES, "50.000", "50.005"))
    assert "fils" in err.value.message


def test_a_mashreq_card_statement_still_reads_as_a_card(tmp_path: Path) -> None:
    pdf = CASES["mashreq_encrypted"].write(tmp_path / "card.pdf")
    out = parse_document(pdf, bank_code_hint="MASHREQ", settings={"MASHREQ_PDF_PASSWORD": PASSWORD})
    assert out["document_kind"] == "statement_pdf"
    assert "account" not in out["statements"][0]
