from __future__ import annotations

from ccs_platform.adapters.banks.browser.banks import fab


def test_fab_option_score_parses_combined_month_year() -> None:
    assert fab._option_score({"text": "February 2026", "value": ""}) == 202602
    assert fab._option_score({"text": "Feb-2024", "value": ""}) == 202402
    assert fab._option_score({"text": "Statement", "value": "202503"}) == 202503


def test_fab_parse_requested_month_and_normalize_tokens() -> None:
    assert fab._parse_requested_month("2025-11") == (2025, 11)
    assert fab._parse_requested_month("latest") == (None, None)
    assert fab._parse_requested_month("bad-token") == (None, None)

    assert fab._normalize_requested_months("2025-01") == ["2025-01"]
    assert fab._normalize_requested_months(["2025-01", "2025-01", "2025-02"]) == ["2025-01", "2025-02"]
