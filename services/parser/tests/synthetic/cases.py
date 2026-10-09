"""Fictional statements, one per bank layout. Nothing here comes from a real statement.

Each case is the text of a PDF (see ``tests/synthetic_pdf.py``) plus the request fields the
worker would send. The expected parser output lives in ``expected/<case>.json``; see
``update.py`` for how it is regenerated and why a change needs a ``PARSER_VERSION`` bump.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from tests.synthetic_pdf import Line, write_pdf

# A test-only password for the encrypted cases (emailed statements are encrypted).
PASSWORD = "synthetic-pass"


@dataclass(frozen=True)
class Case:
    pages: list[list[Line]]
    password: str | None = None
    settings: dict[str, str] = field(default_factory=dict)
    bank_code_hint: str | None = None
    filename: str = "statement.pdf"

    def write(self, path: Path) -> Path:
        return write_pdf(path, self.pages, password=self.password)


# ---------------------------------------------------------------- MASHREQ
# Summary block (DP-12), foreign rows with "<CUR> <amount> @<rate>" (DP-11), a foreign
# credit, a trailing "-" credit marker, and the "<merchant><city> <reference>" row shape.

_MASHREQ_PAGES: list[list[Line]] = [
    [
        "e-statement",
        "Sample VIP Credit Card",
        "JANE Q SAMPLE Statement of account",
        "Card No 4000 XXXX XXXX 1234",
        "Total outstanding balance 1,184.50",
        "Minimum payment due 59.23",
        "Statement date 06/02/2026",
        "Payment due date 05/03/2026",
        "Summary AED",
        "Previous balance 2,000.00",
        "- payments 2,000.00",
        "- other credits 100.00",
        "+ finance charges 0.00",
        "+ other charges 0.00",
        "+ new transactions 1,284.50",
        "+ current balance 1,184.50",
        "+ cash advance 0.00",
        "= outstanding balance 1,184.50",
        "Combined credit limit 20,000.00",
        "Available credit limit 18,815.50",
        "Mashreqbank PSC is regulated by the Central Bank of the United Arab Emirates",
    ],
    [
        "e-statement",
        "transaction dateposting date description transaction reference AED amount",
        "06/01 08/01 corner grocerydubai 74000000000000000000001 120.00",
        "07/01 08/01 noodle housekuala lumpur 2400000001 MYR 500.00 @0.9400 470.00",
        "08/01 09/01 book cornerkuala lumpur 2400000002 MYR 100.00 @0.9500 95.00",
        "10/01 11/01 ticket officetokyo 2400000003 JPY 4000.00 @0.0250 100.00 -",
        "12/01 13/01 cafe lattedubai 74000000000000000000002 599.50",
        "15/01 15/01 payment received thank you 74000000000000000000003 2,000.00 -",
        "Page 2 of 2",
    ],
]

# ---------------------------------------------------------------- ENBD / EIB
# The shared Emirates NBD group template. ENBD prints the Dec/Jan period with the wrong
# year ("29-Dec-25 to 28-Jan-25", DP-03/04); the summary row's Statement Date fixes it.


def _enbd_template(bank_line: str, period: str, card: str, product: str) -> list[list[Line]]:
    return [
        [
            "Credit Card Statement",
            "JANE Q SAMPLE For queries, please call 600 00 0000",
            f"Card Number: {card}",
            f"Card Type: {product}",
            f"Page 1 of 1 Statement Period: {period}",
            "Credit Limit Available Credit Limit (AED) Statement Date Payment Due Date Minimum Payment Due",
            "20000 18,500.00 28/01/2026 22/02/2026 75.00",
            "Transaction Date Posting Date Description Amount",
            "30/12/2025 31/12/2025 CORNER GROCERY DUBAI ARE 250.00",
            "05/01/2026 06/01/2026 ONLINE STORE LONDON GBR 400.00",
            "10/01/2026 10/01/2026 PAYMENT RECEIVED THANK YOU 900.00CR",
            "15/01/2026 16/01/2026 COFFEE SHOP DUBAI ARE 25.00",
            "Previous Statement Due (AED) Purchase / Cash Advance (AED) Interest/Other Charges (AED)"
            " Payments/Credits (AED) Total Payment Due (AED) Current Balance (AED)",
            "1,725.00 675.00 0.00 900.00 1,500.00 1,500.00",
            bank_line,
        ]
    ]


# ---------------------------------------------------------------- FAB
# Column layout (Debit/Credit by x position), a foreign row, a supplementary card, and a
# rewards redemption the summary's Payments/Credits column leaves out (DP-10).

_DEBIT_X, _CREDIT_X = 470, 530


def _fab_row(dates: str, description: str, original: str, aed: str, *, credit: bool = False) -> Line:
    return [(30, f"{dates} {description}"), (330, original), (_CREDIT_X if credit else _DEBIT_X, aed)]


_FAB_PAGES: list[list[Line]] = [
    [
        "MS JANE Q SAMPLE Main Card Product Statement Date Payment Due Date",
        # The address column shares the product line (real layout): "12 SAMPLE TOWER" is not the product.
        "12 SAMPLE TOWER SAMPLE CASHBACK CARD 01-02-2026 26-02-2026",
        "Main Card Number Current Balance Minimum Payment Due",
        "4000 12** **** 2468 1,000.00 100.00",
        "Summary Details",
        "Previous Balance + Purchases/Debits + Cash Advances + Finance Charges - Payments/Credits Total Payment Due",
        "1,500.00 1,200.00 0.00 0.00 1,500.00 1,000.00",
        "Total Credit Limit Available Credit Limit",
        "25,000.00 24,000.00",
        "Transaction Details",
        [(30, "Date"), (80, "Date"), (330, "Amount"), (_DEBIT_X, "Debit"), (_CREDIT_X, "Credit")],
        "Main Card : 4000 12** **** 2468 SAMPLE CASHBACK CARD",
        _fab_row("03-01-2026 03-01-2026", "CORNER GROCERY Dubai ARE", "AED 700.00", "700.00"),
        _fab_row("05-01-2026 05-01-2026", "ONLINE SHOP Dublin IRL", "USD 100.00", "367.50"),
        _fab_row("12-01-2026 12-01-2026", "FAB REWARDS REDEMPTION - CASHBACK", "AED 200.00", "200.00", credit=True),
        _fab_row("15-01-2026 15-01-2026", "PAYMENT RECEIVED - THANK YOU", "AED 1,500.00", "1,500.00", credit=True),
        "Supplementary Card : 4000 12** **** 1357 SAMPLE CASHBACK CARD",
        "JOHN R SAMPLE",
        _fab_row("20-01-2026 20-01-2026", "FUEL STATION Sharjah SHJ", "AED 132.50", "132.50"),
        "First Abu Dhabi Bank P.J.S.C.",
    ]
]

# ---------------------------------------------------------------- ADCB
# Always encrypted. A foreign row followed by its "[1 EUR=AED x]" rate line.

_ADCB_PAGES: list[list[Line]] = [
    [
        "Abu Dhabi Commercial Bank PJSC Credit Card Statement",
        "Statement Date 05/02/26",
        "Card No : 4000XXXXXXXX9876 - JANE Q SAMPLE",
        "PREVIOUS BALANCE OUTSTANDING 1,000.00",
        "10/01/2026 HOTEL SAMPLE PARIS FRA 100.00 EUR 400.00",
        "[1 EUR=AED 4.0000]",
        "12/01/2026 PAYMENT THANK YOU 1,000.00 CR",
        "15/01/2026 CORNER GROCERY ABU DHABI 925.00",
        "NEW BALANCE OUTSTANDING 1,325.00",
        "Page 1 of 1",
    ]
]

# ---------------------------------------------------------------- SIB history
# A transaction-history export: one history_extract per 12th-of-month billing cycle.

_SIB_HISTORY_PAGES: list[list[Line]] = [
    [
        "Transaction history",
        "JANE Q SAMPLE",
        "Date range 01 Jan 2026 - 31 Jan 2026",
        "Account no. 4000 xxxx xxxx 2222",
        "Account type Sample Islamic Card",
        "Currency AED",
        "Date Details Amount",
        "03 Jan 2026 CORNER GROCERY SHARJAH AED -150.00",
        "10 Jan 2026 BOOK SHOP DUBAI AED -45.50",
        "15 Jan 2026 CREDIT CARD PAYMENT AED 500.00",
        "20 Jan 2026 ONLINE STORE LONDON USD -20.00",
        "Sharjah Islamic Bank",
    ]
]

# The same layout for a re-issued card: a new number ("Card no." header, upper-case mask).
# Every line and every billing cycle carries the new last4.
_SIB_HISTORY_NEW_CARD_PAGES: list[list[Line]] = [
    [
        "Transaction history",
        "JANE Q SAMPLE",
        "Date range 01 Aug 2026 - 30 Sep 2026",
        "Card no.: 4000 XXXX XXXX 3333",
        "Account type Sample Islamic Card",
        "Currency AED",
        "Date Details Amount",
        "20 Aug 2026 CORNER GROCERY SHARJAH AED -80.00",
        "02 Sep 2026 FUEL STATION SHARJAH AED -120.25",
        "14 Sep 2026 CREDIT CARD PAYMENT AED 300.00",
        "Sharjah Islamic Bank",
    ]
]


CASES: dict[str, Case] = {
    "mashreq_statement": Case(_MASHREQ_PAGES),
    # X-17: Mashreq and EIB passwords reach their parsers.
    "mashreq_encrypted": Case(_MASHREQ_PAGES, password=PASSWORD, settings={"MASHREQ_PDF_PASSWORD": PASSWORD}),
    "enbd_statement_year_boundary": Case(
        _enbd_template(
            "Emirates NBD Bank (P.J.S.C.) is licensed by the Central Bank of the UAE",
            "29-Dec-25 to 28-Jan-25",
            "4000 XXXX XXXX 5678",
            "Sample One Visa Credit Card",
        )
    ),
    "eib_encrypted": Case(
        _enbd_template(
            "Emirates Islamic Bank is licensed by the Central Bank of the UAE",
            "29-Dec-25 to 28-Jan-26",
            "4000 XXXX XXXX 8765",
            "Sample Islamic Credit Card",
        ),
        password=PASSWORD,
        settings={"EIB_PDF_PASSWORD": PASSWORD},
    ),
    "fab_statement": Case(_FAB_PAGES),
    "adcb_encrypted": Case(_ADCB_PAGES, password=PASSWORD, settings={"ADCB_PDF_PASSWORD": PASSWORD}),
    "sib_history": Case(_SIB_HISTORY_PAGES),
    "sib_history_new_card": Case(_SIB_HISTORY_NEW_CARD_PAGES),
    # SRV-17: a wrong hint (an ADCB hint on a FAB PDF) is detected and retried once.
    "fab_wrong_hint": Case(_FAB_PAGES, bank_code_hint="ADCB"),
}
