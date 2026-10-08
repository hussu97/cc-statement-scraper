"""X-25r: country_code is ISO 3166-1 alpha-2 or null."""

from __future__ import annotations

import pytest

from ccs_parser.countries import ALPHA2, ALPHA3_TO_ALPHA2, normalize_country_code


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("AE", "AE"),
        ("ARE", "AE"),
        ("UAE", "AE"),
        ("DXB", "AE"),
        ("AUH", "AE"),
        ("SHJ", "AE"),
        ("IRL", "IE"),
        ("GBR", "GB"),
        ("USA", "US"),
        ("KEN", "KE"),
        ("SWE", "SE"),
        ("fra", "FR"),
        (" GB ", "GB"),
        # Not countries: words and currencies at the end of a description.
        ("YOU", None),
        ("FEE", None),
        ("USD", None),
        ("KNE", None),
        ("ZZ", None),
        ("VAT", None),
        ("CAN", None),
        ("", None),
        (None, None),
        ("AREA", None),
    ],
)
def test_normalize_country_code(raw: str | None, expected: str | None) -> None:
    assert normalize_country_code(raw) == expected


def test_table_is_complete_and_consistent() -> None:
    assert len(ALPHA3_TO_ALPHA2) == 249
    assert len(ALPHA2) == 249
    assert all(len(a3) == 3 and len(a2) == 2 and a3.isupper() and a2.isupper() for a3, a2 in ALPHA3_TO_ALPHA2.items())
