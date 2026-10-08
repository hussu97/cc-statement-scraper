"""SRV-01: every parse is bounded in CPU, wall clock, pages, size and inflated bytes."""

from __future__ import annotations

import time
import zlib

import pytest

from ccs_parser import limits
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.service import parse_document
from tests import limits_helpers as h


@pytest.fixture(autouse=True)
def _restore_pdfminer_zlib():
    """Inline runs install the bounded zlib in this process; don't leak it into other tests."""
    import pdfminer.pdftypes as pdftypes

    yield
    pdftypes.zlib = zlib


@pytest.fixture(autouse=True)
def _defaults(monkeypatch) -> None:
    for name in (
        "PARSER_ISOLATION",
        "PARSER_MAX_PAGES",
        "PARSER_MAX_PDF_MB",
        "PARSER_CPU_LIMIT_SECONDS",
        "PARSER_PARSE_TIMEOUT_SECONDS",
        "PARSER_MEMORY_LIMIT_MB",
        "PARSER_MAX_INFLATE_MB",
    ):
        monkeypatch.delenv(name, raising=False)


# ---------------------------------------------------------------- config


def test_defaults_and_overrides(monkeypatch) -> None:
    assert limits.max_pages() == 30
    assert limits.cpu_limit_seconds() == 30
    assert limits.parse_timeout_seconds() == 60
    assert limits.isolation_enabled() is True
    monkeypatch.setenv("PARSER_MAX_PAGES", "5")
    monkeypatch.setenv("PARSER_CPU_LIMIT_SECONDS", "garbage")
    monkeypatch.setenv("PARSER_ISOLATION", "inline")
    assert limits.max_pages() == 5
    assert limits.cpu_limit_seconds() == 30
    assert limits.isolation_enabled() is False


# ---------------------------------------------------------------- document checks


def test_rejects_too_many_pages(tmp_path, monkeypatch) -> None:
    pdf = h.make_blank_pdf(tmp_path / "many.pdf", 31)
    with pytest.raises(ParserError) as err:
        limits.check_document_limits(pdf, [])
    assert err.value.code == "PDF_TOO_LARGE"
    monkeypatch.setenv("PARSER_MAX_PAGES", "40")
    limits.check_document_limits(pdf, [])


def test_rejects_oversize_file(tmp_path, monkeypatch) -> None:
    pdf = h.make_blank_pdf(tmp_path / "one.pdf", 1)
    monkeypatch.setenv("PARSER_MAX_PDF_MB", "0.0001")
    with pytest.raises(ParserError) as err:
        limits.check_document_limits(pdf, [])
    assert err.value.code == "PDF_TOO_LARGE"


def test_parse_document_checks_limits_first(tmp_path, monkeypatch) -> None:
    pdf = h.make_blank_pdf(tmp_path / "many.pdf", 31)
    monkeypatch.setenv("PARSER_ISOLATION", "inline")
    with pytest.raises(ParserError) as err:
        limits.run_parse(parse_document, pdf)
    assert err.value.code == "PDF_TOO_LARGE"


def test_unreadable_file_is_left_to_the_parser(tmp_path) -> None:
    junk = tmp_path / "junk.pdf"
    junk.write_bytes(b"%PDF-1.4 not really")
    assert limits.count_pages(junk, []) is None
    limits.check_document_limits(junk, [])


# ---------------------------------------------------------------- inflate guard


def test_bounded_zlib_matches_zlib_within_budget() -> None:
    shim = limits._BoundedZlib(10 * 1024 * 1024)
    data = b"hello world " * 1000
    assert shim.decompress(zlib.compress(data)) == data
    assert shim.used == len(data)
    with pytest.raises(zlib.error):
        shim.decompress(zlib.compress(data)[:-10])
    obj = shim.decompressobj()
    assert obj.decompress(zlib.compress(data)) + obj.flush() == data


def test_bounded_zlib_stops_a_bomb_without_inflating_it() -> None:
    shim = limits._BoundedZlib(1024 * 1024)
    bomb = zlib.compress(b"\0" * (64 * 1024 * 1024), 9)
    with pytest.raises(limits.InflateBudgetExceeded):
        shim.decompress(bomb)
    shim2 = limits._BoundedZlib(1024 * 1024)
    with pytest.raises(limits.InflateBudgetExceeded):
        shim2.decompressobj().decompress(bomb)


def test_inflate_budget_is_cumulative_per_parse() -> None:
    shim = limits._BoundedZlib(1000)
    shim.decompress(zlib.compress(b"a" * 600))
    with pytest.raises(limits.InflateBudgetExceeded):
        shim.decompress(zlib.compress(b"a" * 600))


# ---------------------------------------------------------------- isolation


def test_isolated_returns_result() -> None:
    assert limits.run_isolated(h.add, 2, b=3) == {"sum": 5}


def test_isolated_propagates_parser_errors() -> None:
    with pytest.raises(ParserError) as err:
        limits.run_isolated(h.raise_parser_error)
    assert (err.value.code, err.value.message) == ("UNSUPPORTED_LAYOUT", "layout not recognised")


def test_isolated_crash_is_internal_and_never_echoes_the_message() -> None:
    with pytest.raises(limits.ParseCrashed) as err:
        limits.run_isolated(h.raise_secret_value_error)
    assert "ValueError" in str(err.value)
    assert "CARREFOUR" not in str(err.value)


def test_isolated_sees_request_time_parser_env(monkeypatch) -> None:
    monkeypatch.setenv("PARSER_MAX_PAGES", "7")
    assert limits.run_isolated(h.read_env, "PARSER_MAX_PAGES") == "7"
    monkeypatch.delenv("PARSER_MAX_PAGES")
    assert limits.run_isolated(h.read_env, "PARSER_MAX_PAGES") is None


def test_cpu_limit_kills_a_busy_parse(monkeypatch) -> None:
    monkeypatch.setenv("PARSER_CPU_LIMIT_SECONDS", "1")
    started = time.monotonic()
    with pytest.raises(ParserError) as err:
        limits.run_isolated(h.burn_cpu)
    assert err.value.code == "PARSE_TIMEOUT"
    assert time.monotonic() - started < 10


def test_wall_clock_limit_kills_a_stuck_parse(monkeypatch) -> None:
    monkeypatch.setenv("PARSER_PARSE_TIMEOUT_SECONDS", "1")
    started = time.monotonic()
    with pytest.raises(ParserError) as err:
        limits.run_isolated(h.sleep_forever)
    assert err.value.code == "PARSE_TIMEOUT"
    assert time.monotonic() - started < 10


def test_child_installs_the_inflate_guard(monkeypatch) -> None:
    monkeypatch.setenv("PARSER_MAX_INFLATE_MB", "1")
    with pytest.raises(ParserError) as err:
        limits.run_isolated(h.inflate_through_pdfminer, 4 * 1024 * 1024)
    assert err.value.code == "PDF_TOO_LARGE"
    assert limits.run_isolated(h.inflate_through_pdfminer, 512 * 1024) == 512 * 1024


# ---------------------------------------------------------------- the audit's crafted PDF


def test_decompression_bomb_pdf_is_rejected_quickly(tmp_path) -> None:
    """mkbomb.py 64: 65 KB on disk, 64 MB of operators. Took 202 s CPU before SRV-01."""
    pdf = h.make_bomb_pdf(tmp_path / "bomb.pdf", 64)
    assert pdf.stat().st_size < 100_000
    started = time.monotonic()
    with pytest.raises(ParserError) as err:
        limits.run_parse(parse_document, pdf)
    assert err.value.code == "PDF_TOO_LARGE"
    assert time.monotonic() - started < 10


def test_decompression_bomb_is_too_large_inline_too(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("PARSER_ISOLATION", "inline")
    pdf = h.make_bomb_pdf(tmp_path / "bomb.pdf", 64)
    with pytest.raises(ParserError) as err:
        limits.run_parse(parse_document, pdf)
    assert err.value.code == "PDF_TOO_LARGE"


def test_operator_flood_under_the_inflate_budget_hits_the_cpu_limit(tmp_path, monkeypatch) -> None:
    pdf = h.make_bomb_pdf(tmp_path / "flood.pdf", 24)
    monkeypatch.setenv("PARSER_CPU_LIMIT_SECONDS", "2")
    started = time.monotonic()
    with pytest.raises(ParserError) as err:
        limits.run_parse(parse_document, pdf)
    assert err.value.code == "PARSE_TIMEOUT"
    assert time.monotonic() - started < 15
