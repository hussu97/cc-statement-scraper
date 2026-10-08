"""SIB replaced card: the portal lists the retired card next to its successor, so the adapter
exports every listed (or configured) card instead of the first "credit card" match."""

from __future__ import annotations

import ast
import logging
from pathlib import Path

import pytest

from scraper.banks.adapters import sib
from scraper.banks.adapters.sib import card_last4s_in_text, parse_card_last4s, wanted_card_last4s

SIB_SOURCE = Path(sib.__file__)


def test_card_last4s_in_text_reads_masked_numbers_in_order() -> None:
    text = """
    SIB MC CASHBACK  5290 xxxx xxxx 6774  Replaced
    SIB MC CASHBACK  5290 XXXX XXXX 4821  Active
    Available limit AED 9,000.00   ref 1234 5678
    529012** **** 4821
    """
    assert card_last4s_in_text(text) == ["6774", "4821"]
    assert card_last4s_in_text("no cards here, AED 1,234.00 on 12/03/2026") == []


def test_parse_card_last4s_accepts_lists_and_strings() -> None:
    assert parse_card_last4s("4821, 6774") == ["4821", "6774"]
    assert parse_card_last4s(["4821", 6774, "x", "4821"]) == ["4821", "6774"]
    assert parse_card_last4s(4821) == ["4821"]
    assert parse_card_last4s(None) == []
    assert parse_card_last4s("") == []


def test_wanted_cards_prefers_configuration_then_every_listed_card() -> None:
    assert wanted_card_last4s(["6774", "4821"], []) == ["6774", "4821"]
    assert wanted_card_last4s(["6774", "4821"], ["4821"]) == ["4821"]
    assert wanted_card_last4s([], []) == []


class _Page:
    """Enough of a Playwright page for download_latest_statement's control flow."""


def test_download_exports_each_card_and_tags_diagnostics(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    calls: list[str | None] = []

    def fake_download(_page, _dir, _logger, months, card):
        calls.append(card)
        return 1, {"downloaded": [{"month": months[0] if months else "latest", "path": f"/x/{card}.pdf"}],
                   "skipped_unavailable": [], "failed": []}

    monkeypatch.setattr(sib, "_discover_card_last4s", lambda _p, _l: ["6774", "4821"])
    monkeypatch.setattr(sib, "_download_for_card", fake_download)
    monkeypatch.delenv("SIB_CARD_LAST4S", raising=False)
    cfg: dict = {}
    assert sib.download_latest_statement(_Page(), tmp_path, logging.getLogger("t"), cfg) == 2
    assert calls == ["6774", "4821"]
    assert [d["card_last4"] for d in cfg["download_diagnostics"]["downloaded"]] == ["6774", "4821"]
    assert cfg["download_diagnostics"]["cards"] == ["6774", "4821"]

    calls.clear()
    monkeypatch.setenv("SIB_CARD_LAST4S", "4821")
    cfg = {"requested_months": ["2026-09"]}
    assert sib.download_latest_statement(_Page(), tmp_path, logging.getLogger("t"), cfg) == 1
    assert calls == ["4821"]


def test_download_without_a_card_choice_keeps_the_single_card_flow(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    calls: list[str | None] = []
    monkeypatch.setattr(sib, "_discover_card_last4s", lambda _p, _l: [])
    monkeypatch.setattr(
        sib,
        "_download_for_card",
        lambda _p, _d, _l, _m, card: (calls.append(card) or 0, {"downloaded": [], "skipped_unavailable": [],
                                                                "failed": [{"month": "latest", "reason": "x"}]}),
    )
    monkeypatch.delenv("SIB_CARD_LAST4S", raising=False)
    cfg: dict = {}
    assert sib.download_latest_statement(_Page(), tmp_path, logging.getLogger("t"), cfg) == 0
    assert calls == [None]
    assert cfg["download_diagnostics"]["failed"] == [{"month": "latest", "reason": "x"}]


def _calls_in_order(tree: ast.AST) -> list[ast.Call]:
    return sorted((n for n in ast.walk(tree) if isinstance(n, ast.Call)), key=lambda c: (c.lineno, c.col_offset))


def test_every_long_wait_in_the_sib_adapter_is_logged_first() -> None:
    """CLAUDE.md §7: a logger.info("SIB: waiting …") right before every wait_for_timeout of
    700 ms or more, every expect_download and every time.sleep."""
    tree = ast.parse(SIB_SOURCE.read_text())
    lines = SIB_SOURCE.read_text().splitlines()
    problems = []
    for call in _calls_in_order(tree):
        func = call.func
        name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", "")
        if name not in {"wait_for_timeout", "expect_download", "sleep"}:
            continue
        if name == "wait_for_timeout":
            arg = call.args[0] if call.args else None
            if not (isinstance(arg, ast.Constant) and isinstance(arg.value, int) and arg.value >= 700):
                continue
        # The nearest preceding non-blank line(s) must hold the logger.info("SIB: waiting …") call.
        start = call.lineno - 2
        window = "\n".join(lines[max(0, start - 6): start + 1])
        if "logger.info(" not in window or "SIB: waiting" not in window:
            problems.append(f"line {call.lineno}: {name}")
    assert problems == []
