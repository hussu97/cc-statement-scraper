from __future__ import annotations

import pytest

from scraper.banks.month_utils import MONTH_INDEX


def test_all_twelve_months_covered() -> None:
    assert set(MONTH_INDEX.values()) == set(range(1, 13))


def test_full_month_names() -> None:
    expected = {
        "january": 1, "february": 2, "march": 3, "april": 4,
        "may": 5, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12,
    }
    for name, number in expected.items():
        assert MONTH_INDEX[name] == number, f"{name!r} → {number}"


def test_standard_abbreviations() -> None:
    expected = {
        "jan": 1, "feb": 2, "mar": 3, "apr": 4,
        "jun": 6, "jul": 7, "aug": 8,
        "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    }
    for abbrev, number in expected.items():
        assert MONTH_INDEX[abbrev] == number, f"{abbrev!r} → {number}"


def test_sept_abbreviation() -> None:
    # Some bank portals use "Sept" — ensure it's mapped
    assert MONTH_INDEX["sept"] == 9


def test_all_keys_are_lowercase() -> None:
    """Keys are all lowercase so callers must .lower() before lookup."""
    for key in MONTH_INDEX:
        assert key == key.lower(), f"key {key!r} is not lowercase"


@pytest.mark.parametrize("key,expected", [
    ("january", 1),
    ("march", 3),
    ("september", 9),
    ("december", 12),
    ("jan", 1),
    ("sep", 9),
    ("sept", 9),
    ("dec", 12),
])
def test_spot_checks(key: str, expected: int) -> None:
    assert MONTH_INDEX[key] == expected
