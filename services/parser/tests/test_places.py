from __future__ import annotations

from datetime import date

import pytest

from ccs_parser.domain.statements.types import ParsedLine
from ccs_parser.places import separate_glued_place
from ccs_parser.service import _line_out


@pytest.mark.parametrize(
    ("merchant", "expected"),
    [
        # Mashreq / SIB: the city column glued to the name
        ("CAREEM HALA RIDEDUBAI", "CAREEM HALA RIDE DUBAI"),
        ("CAREEM HALAABU DHABI", "CAREEM HALA ABU DHABI"),
        ("ADNOC MAYSALOON 783SHARJAH", "ADNOC MAYSALOON 783 SHARJAH"),
        ("JAYS ONE SWEET AND FLOWERAL AIN", "JAYS ONE SWEET AND FLOWER AL AIN"),
        ("THE COVE ROTANA RESORT RARAS AL KHAIMA", "THE COVE ROTANA RESORT RA RAS AL KHAIMA"),
        ("WATSON S NU SENTRAL M523KUALA LUMPUR", "WATSON S NU SENTRAL M523 KUALA LUMPUR"),
        ("PRISON ISLAND DUBAIDXB", "PRISON ISLAND DUBAI DXB"),
        ("THE SURF CAFEAUH", "THE SURF CAFE AUH"),
        # already spaced, or no city at the end: unchanged
        ("CAREEM HALA RIDE DUBAI", "CAREEM HALA RIDE DUBAI"),
        ("CARREFOUR CITY CENTRE DUBAI AE", "CARREFOUR CITY CENTRE DUBAI AE"),
        ("DUBAI ELECTRICITY", "DUBAI ELECTRICITY"),
        ("SMART DUBAI GOVERNMENT", "SMART DUBAI GOVERNMENT"),
        ("ABU KADRA CAFE", "ABU KADRA CAFE"),
        ("DUBAI", "DUBAI"),
        ("", ""),
    ],
)
def test_separate_glued_place(merchant: str, expected: str) -> None:
    assert separate_glued_place(merchant) == expected


def test_only_merchant_normalized_changes() -> None:
    """description_raw is the evidence and feeds line_key; the fingerprint is the legacy one."""
    line = ParsedLine(
        line_no=1,
        transaction_date=date(2026, 8, 6),
        transaction_time=None,
        posting_date=date(2026, 8, 7),
        merchant_raw="careem hala ridedubai",
        merchant_normalized="CAREEM HALA RIDEDUBAI",
        amount_original=86.5,
        currency_original="AED",
        amount_aed=86.5,
        fx_rate_to_aed=1.0,
        direction="debit",
        transaction_kind="purchase",
        country_code=None,
        card_last4="1234",
        card_holder=None,
        fingerprint="a" * 64,
    )
    out = _line_out(line)
    assert out["description_raw"] == "careem hala ridedubai"
    assert out["merchant_normalized"] == "CAREEM HALA RIDE DUBAI"
    assert out["legacy_fingerprint"] == "a" * 64


def test_places_match_the_database() -> None:
    """The backfill migration's private.separate_glued_place knows exactly these places."""
    import re
    from pathlib import Path

    from ccs_parser.places import PLACES

    migration = Path(__file__).resolve().parents[3] / "supabase/migrations/20261010001300_glued_place_backfill.sql"
    body = migration.read_text()
    alternation = re.search(r"'\(\[\[:alnum:\]\]\)\((.*?)\)\$'", body, re.S)
    assert alternation, "pattern not found in the migration"
    sql_places = set("".join(re.findall(r"'([^']*)'", "'" + alternation.group(1) + "'")).split("|"))
    assert sql_places == set(PLACES)
