"""Separate a city glued to the merchant name in ``lines[].merchant_normalized``.

Some statements print the merchant and city columns as one text run with no space between
them: the PDF itself holds ``careem hala ridedubai`` (Mashreq), and SIB history extracts read
``EMIRATES HOSPITALSDUBAI``. No layout setting recovers the space, so a city from this list
that ends the text right after a letter or digit gets one: ``CAREEM HALA RIDE DUBAI``.

Only ``merchant_normalized`` changes. ``description_raw`` stays as the bank printed it: it is
the evidence, and ingest hashes it into the line's identity (``line_key``), so a re-parse or an
overlapping history export still finds the same lines. The legacy fingerprint is computed by
the bank parsers before this runs and is unchanged.

The places mirror ``c_place`` in ``public.merchant_key`` (supabase migration
20261010001200_merchant_key_v2), which strips them glued or not; add a place to both.
"""

from __future__ import annotations

import re

PLACES: tuple[str, ...] = (
    # United Arab Emirates
    "DUBAI", "DXB", "ABU DHABI", "ABUDHABI", "AUH", "SHARJAH", "SHJ", "AJMAN", "AL AIN", "FUJAIRAH",
    "RAS AL KHAIMAH", "RAS AL KHAIMA", "UMM AL QUWAIN",
    # elsewhere, as seen on statements
    "LONDON", "NEW YORK", "SAN FRANCISCO", "MOUNTAIN VIEW", "PALO ALTO", "PHOENIX", "PITTSBURGH",
    "BOSTON", "DUBLIN", "AMSTERDAM", "STOCKHOLM", "BERLIN", "SINGAPORE", "KUALA LUMPUR",
    "PETALING JAYA", "SEPANG", "IPOH", "BANGKOK", "PHUKET", "KRABI", "CAIRO", "NAIROBI", "MOMBASA",
    "HYDERABAD", "DELHI", "GURUGRAM", "GURGAON", "KUWAIT", "DOHA", "RIYADH", "JEDDAH", "MUSCAT", "MANAMA",
)  # fmt: skip

# Longest first, so "RAS AL KHAIMAH" wins over "RAS AL KHAIMA" at the same position.
_GLUED_PLACE_RE = re.compile(
    r"(?<=[A-Z0-9])(" + "|".join(re.escape(p) for p in sorted(PLACES, key=len, reverse=True)) + r")$"
)


def separate_glued_place(merchant: str) -> str:
    """``merchant`` (upper case) with a space before a city glued to its last word."""
    return _GLUED_PLACE_RE.sub(r" \1", merchant, count=1)
