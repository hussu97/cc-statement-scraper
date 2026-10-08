"""X-06 / DP-03 / DP-04 / DP-07: the parser never emits values the database rejects."""

from __future__ import annotations

import copy
from datetime import date
from pathlib import Path

import pytest
from pydantic import ValidationError

from ccs_parser import parser_adapter, service
from ccs_parser.banks import eib, enbd, fab
from ccs_parser.contract import ParseResponse
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.domain.parsing.period_years import resolve_period_years

from .conftest import make_result, make_tx

# ---------------------------------------------------------------- synthetic ENBD/EIB text


class _FakePage:
    def __init__(self, text: str) -> None:
        self._text = text

    def extract_text(self) -> str:
        return self._text


class _FakePdf:
    def __init__(self, text: str) -> None:
        self.pages = [_FakePage(text)]

    def __enter__(self) -> _FakePdf:
        return self

    def __exit__(self, *_exc) -> bool:
        return False


def _enbd_text(period: str, statement_date: str, due_date: str, rows: list[str]) -> str:
    """Mimics the real layout: header period line, summary row with full-year dates, rows."""
    return "\n".join(
        [
            f"Page 1 of 4 Statement Period: {period}",
            "Card Number: 4652 75XX XXXX 1234",
            "Card Type: Visa Platinum",
            "Credit Limit Available Credit Limit (AED) Statement Date Payment Due Date Minimum Payment Due",
            f"20000 18,498.82 {statement_date} {due_date} 100.00",
            "Transaction Date Posting Date Description Amount",
            *rows,
        ]
    )


JAN_ROWS = ["27/12/2025 29/12/2025 NOON MINUTES DUBAI ARE 91.67", "25/01/2026 27/01/2026 NOON DUBAI ARE 732.68"]
DEC_ROWS = ["28/11/2025 30/11/2025 NOON DUBAI ARE 4,794.00", "23/12/2025 25/12/2025 NOON MINUTES DUBAI ARE 27.70"]


@pytest.mark.parametrize("module", [enbd, eib], ids=["ENBD", "EIB"])
@pytest.mark.parametrize(
    ("period", "stmt", "due", "rows", "expected"),
    [
        # DP-03: January statement prints the start with the end's year.
        ("29-Dec-26 to 28-Jan-26", "28/01/2026", "22/02/2026", JAN_ROWS, ("2025-12-29", "2026-01-28")),
        # DP-04: December statement prints the end with the due date's year.
        ("29-Nov-25 to 28-Dec-26", "28/12/2025", "22/01/2026", DEC_ROWS, ("2025-11-29", "2025-12-28")),
        # Ordinary month: untouched.
        ("29-Jun-25 to 28-Jul-25", "28/07/2025", "22/08/2025", ["01/07/2025 02/07/2025 SHOP ARE 10.00"],
         ("2025-06-29", "2025-07-28")),
    ],
    ids=["jan", "dec", "normal"],
)
def test_enbd_family_period_years(monkeypatch, module, period, stmt, due, rows, expected) -> None:
    text = _enbd_text(period, stmt, due, rows)
    monkeypatch.setattr(module.pdfplumber, "open", lambda *_a, **_k: _FakePdf(text))
    parse = enbd.parse_enbd_statement if module is enbd else eib.parse_eib_statement
    result = parse(Path("dummy.pdf"))
    md = result.metadata
    assert (md["statement_period_start"], md["statement_period_end"]) == expected
    assert md["statement_date"] == expected[1]
    assert result.statement_month == expected[1][:7]
    assert all(tx.statement_month == expected[1][:7] for tx in result.transactions)
    corrected = any("year corrected" in w for w in result.warnings)
    assert corrected == (period.split(" to ") != [date.fromisoformat(d).strftime("%d-%b-%y") for d in expected])


def test_enbd_without_summary_row_uses_transaction_dates(monkeypatch) -> None:
    text = "\n".join(["Statement Period: 29-Dec-26 to 28-Jan-26", *JAN_ROWS])
    monkeypatch.setattr(enbd.pdfplumber, "open", lambda *_a, **_k: _FakePdf(text))
    md = enbd.parse_enbd_statement(Path("dummy.pdf")).metadata
    assert (md["statement_period_start"], md["statement_period_end"]) == ("2025-12-29", "2026-01-28")


@pytest.mark.parametrize(
    ("start", "end", "kwargs", "expected"),
    [
        (date(2025, 12, 29), date(2025, 1, 28), {"statement_date": date(2025, 1, 28)}, (date(2024, 12, 29), date(2025, 1, 28))),
        (date(2025, 11, 29), date(2026, 12, 28), {"statement_date": date(2025, 12, 28)}, (date(2025, 11, 29), date(2025, 12, 28))),
        (date(2025, 11, 29), date(2026, 12, 28), {"newest_posting": date(2025, 12, 25)}, (date(2025, 11, 29), date(2025, 12, 28))),
        (date(2025, 12, 29), date(2025, 1, 28), {}, (date(2024, 12, 29), date(2025, 1, 28))),
        (date(2025, 6, 1), date(2025, 6, 30), {"statement_date": date(2025, 6, 30)}, (date(2025, 6, 1), date(2025, 6, 30))),
    ],
)
def test_resolve_period_years(start, end, kwargs, expected) -> None:
    got_start, got_end, _ = resolve_period_years(start, end, **kwargs)
    assert (got_start, got_end) == expected
    assert got_start <= got_end


# ---------------------------------------------------------------- contract mirrors DB constraints


def _valid_response() -> dict:
    line = {
        "line_no": 1, "txn_date": "2026-01-02", "txn_time": None, "posting_date": "2026-01-03",
        "description_raw": "SHOP", "merchant_normalized": "SHOP", "amount_original": "10.00",
        "currency_original": "AED", "amount_aed": "10.00", "fx_rate": "1", "direction": "debit",
        "kind": "purchase", "country_code": None, "card_last4": "1234", "card_holder": None,
        "legacy_fingerprint": "a" * 64,
    }
    totals = dict.fromkeys(("opening_balance", "closing_balance", "total_debits", "total_credits", "min_due", "credit_limit"))
    statement = {
        "kind": "statement", "bank_code": "ENBD", "statement_reference": "R1", "reference_source": "explicit",
        "statement_date": "2026-01-28", "period_start": "2025-12-29", "period_end": "2026-01-28",
        "due_date": "2026-02-22", "primary_card_last4": "1234", "card_holder": None, "card_type": None,
        "totals": totals, "warnings": [], "metadata": {}, "lines": [line],
    }
    return {"contract_version": 1, "parser_version": "x", "bank_code": "ENBD", "document_kind": "statement_pdf",
            "statements": [statement]}


def test_valid_response_passes() -> None:
    ParseResponse.model_validate(_valid_response())


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("period_start",), "2026-12-29"),  # after period_end (statements_check)
        (("period_end",), "2027-01-28"),  # 13-month statement period
        (("due_date",), "2026-01-22"),  # before the statement date
        (("statement_date",), "2026-02-30"),  # not a calendar date
        (("statement_date",), "1970-01-01"),  # outside sane years
        (("primary_card_last4",), "12X4"),
        (("lines", 0, "card_last4"), "123"),
        (("lines", 0, "txn_time"), "25:61"),
        (("lines", 0, "txn_date"), "2026-13-01"),
        (("lines", 0, "amount_original"), "-1.00"),
        (("lines", 0, "amount_aed"), "1234567890123.00"),  # numeric(14,2) overflow
        (("lines", 0, "fx_rate"), "0"),  # fx_rate > 0
        (("lines", 0, "kind"), "transfer"),
        (("lines", 0, "country_code"), "ARE"),  # ISO alpha-2 only (X-25r)
        (("lines", 0, "country_code"), "ae"),
    ],
)
def test_contract_rejects_what_the_db_rejects(path, value) -> None:
    body = _valid_response()
    target = body["statements"][0]
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    with pytest.raises(ValidationError):
        ParseResponse.model_validate(body)


def test_history_extract_may_span_more_than_a_statement_period() -> None:
    body = copy.deepcopy(_valid_response())
    st = body["statements"][0]
    st.update(kind="history_extract", period_start="2025-01-01", period_end="2026-01-28", due_date=None)
    ParseResponse.model_validate(body)


@pytest.fixture
def stub_parser(monkeypatch):
    def _install(result):
        monkeypatch.setattr(parser_adapter, "parse_statement_for_bank", lambda *_a, **_k: result)
        monkeypatch.setattr(service, "detect_bank_code", lambda *_a, **_k: "ENBD")
        monkeypatch.setattr(service, "read_text_lines", lambda *_a, **_k: None)

    return _install


def test_invalid_output_is_permanent_parse_output_invalid(pdf_file, stub_parser) -> None:
    stub_parser(make_result([make_tx(desc="SHOP", amount_aed=10.0)], metadata={
        "statement_date": "2026-01-28", "statement_period_start": "2026-12-29", "statement_period_end": "2026-01-28",
    }))
    with pytest.raises(ParserError) as err:
        service.parse_document(pdf_file)
    assert err.value.code == "PARSE_OUTPUT_INVALID"
    assert "period_start is after period_end" in err.value.message


def test_invalid_output_message_never_echoes_values(pdf_file, stub_parser) -> None:
    tx = make_tx(desc="SHOP", amount_aed=10.0)
    tx.currency_original = "SECRETX"
    stub_parser(make_result([tx]))
    with pytest.raises(ParserError) as err:
        service.parse_document(pdf_file)
    assert err.value.code == "PARSE_OUTPUT_INVALID"
    assert "SECRETX" not in err.value.message
    assert "currency_original" in err.value.message


def test_malformed_last4_is_dropped_not_fatal(pdf_file, stub_parser) -> None:
    stub_parser(make_result([make_tx(desc="SHOP", amount_aed=10.0, last4="12X4")],
                            metadata={"statement_date": "2026-01-28", "card_last4": "XX12"}))
    st = service.parse_document(pdf_file)["statements"][0]
    assert st["primary_card_last4"] is None
    assert st["lines"][0]["card_last4"] is None


# ---------------------------------------------------------------- DP-07: FAB original-currency formats


def _words(tokens: list[tuple[str, float]]) -> list[dict]:
    return [{"text": t, "x0": x, "x1": x + 30, "top": 100.0} for t, x in tokens]


@pytest.mark.parametrize(
    ("original", "expected"),
    [("108,99", "108.99"), ("1.234,56", "1234.56"), ("18.750", "18.750"), ("2,320.00", "2,320.00")],
)
def test_fab_row_accepts_foreign_amount_formats(original, expected) -> None:
    row = _words([("24-08-2025", 41), ("25-08-2025", 90), ("12GO", 140), ("Nicosia", 180), ("CYP", 220),
                  ("EUR", 330), (original, 370), ("487.52", 440)])
    parsed = fab._parse_txn_row(row, debit_x=455.0, credit_x=530.0)
    assert parsed is not None
    assert parsed["amount_original_str"] == expected
    assert parsed["amount_aed_str"] == "487.52"
    assert parsed["is_credit"] is False


def test_fab_row_still_requires_a_dot_decimal_aed_amount() -> None:
    row = _words([("24-08-2025", 41), ("25-08-2025", 90), ("SHOP", 140), ("EUR", 330), ("108,99", 370),
                  ("487,52", 440)])
    assert fab._parse_txn_row(row, debit_x=455.0, credit_x=530.0) is None
