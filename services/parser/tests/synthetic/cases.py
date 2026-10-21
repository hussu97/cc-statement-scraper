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


# ENBD dnata Platinum (2026): foreign rows end with the original amount and currency, and the
# next line prints the rate; the Credit Shield premium and its VAT are bank charges (fees).
_ENBD_FX_PAGES: list[list[Line]] = [
    [
        "Credit Card Statement",
        "JANE Q For queries, please call 600 54 0000",
        "Card Number: 5000 XXXX XXXX 2468",
        "DUBAI, Card Type: dnata Platinum",
        "UAE Page 1 of 4 Statement Period: 13-Jul-26 to 12-Aug-26",
        "Credit Limit Available Credit Limit (AED) Statement Date Payment Due Date Minimum Payment Due",
        "13000 4,992.58 12/08/2026 06/09/2026 474.91",
        "Transaction Date Posting Date Description Amount",
        "Primary Card Number",
        "JANE Q: 5000 XXXX XXXX 2468",
        "14/07/2026 15/07/2026 *AIRPORT KIOSK CAIRO EGY 505.00 EGP 38.13",
        "(1 AED = EGP 13.24416)",
        "25/07/2026 25/07/2026 TRANSFER PAYMENT RECEIVED THANK YOU 8,044.00CR",
        "29/07/2026 30/07/2026 *SAMPLE INSURER DOUGLAS GBR 2,000.00 USD 7,575.08",
        "(1 AED = USD 0.26402)",
        "03/08/2026 04/08/2026 CORNER GROCERY DUBAI ARE 350.10",
        "12/08/2026 12/08/2026 CREDIT SHIELD PRO PREMIUM 78.46",
        "12/08/2026 12/08/2026 VAT ON INSURANCE 3.92",
        "Previous Statement Purchase / Cash Interest/Other Payments/Credits (AED) Total Payment Due (AED)"
        " Current Balance (AED)",
        "Due (AED) Advance (AED) Charges (AED)",
        "8,005.73 7,963.31 82.38 8,044.00 8,007.42 8,007.42",
        "Emirates NBD Bank (P.J.S.C.) is licensed by the Central Bank of the UAE",
    ]
]


# ---------------------------------------------------------------- EIB card account
# The layout EIB sends: the period on two lines, "DD MON" rows (post date first) with no
# year (this period crosses Dec/Jan), a foreign row and its "*(1 AED = GBP x)" rate line,
# a supplementary card section, a merchant credit (a refund) and a payment.

_EIB_CARD_ACCOUNT_PAGES: list[list[Line]] = [
    [
        "Statement of Card Account",
        "JANE Q PAGE 1 OF 1",
        "SAMPLE Card Account Number.: 4000 XXXX XXXX 1234",
        "1 SAMPLE TOWER",
        "DUBAI Statement Period:",
        "From:16th Dec 2025",
        "To:15th Jan 2026",
        "Description Amount",
        "Post Date Trxn. Date",
        "OPENING BALANCE 1,000.00",
        "PRIMARY CARD NO:4000XXXXXXXX1234",
        "17 DEC 16 DEC CORNER GROCERY DUBAI ARE 250.00",
        "02 JAN 30 DEC ONLINE SHOP LONDON GBR 100.00 GBP 470.00",
        "*(1 AED = GBP 0.21277)",
        "08 JAN 07 JAN AMAZON RETAIL DUBAI ARE 200.00CR",
        "10 JAN 10 JAN TRANSFER PAYMENT RECEIVED THANK YOU 1,000.00CR",
        "SUPPLEMENTARY CARD NO:4000XXXXXXXX8765",
        "05 JAN 04 JAN FUEL STATION SHARJAH ARE 120.00",
        "06 JAN 06 JAN CAFE 24 DUBAI ARE 15.00",
        "Card Limit Available Limit Minimum Payment Due Payment Due Date Total Payment Due"
        " Profit/Other Charges (AED) Current Balance (AED)",
        "20,000.00 19,345.00 100.00 09/02/26 655.00 0.00 655.00",
        "Emirates Islamic Bank (P.J.S.C.) is licensed by the Central Bank of the UAE.",
    ]
]

# The same layout in another month's extraction order: the card number on the name line
# with a bare "Card Account Number.:", the period end before its "To:" label, and no
# activity (no OPENING BALANCE line, no card section; the balance carries over).
_EIB_CARD_ACCOUNT_QUIET_PAGES: list[list[Line]] = [
    [
        "Statement of Card Account",
        "JANE Q 4000 XXXX XXXX 2222 PAGE 1 OF 1",
        "Card Account Number.:",
        "SAMPLE",
        "1 SAMPLE TOWER",
        "DUBAI Statement Period:",
        "From:11th Jun 2026",
        "10th Jul 2026",
        "To:",
        "Description Amount",
        "Post Date Trxn. Date",
        "Rewards Summary",
        "CASHBACK OPENING BALANCE 0",
        "Card Limit Available Limit Minimum Payment Due Payment Due Date Total Payment Due"
        " Profit/Other Charges (AED) Current Balance (AED)",
        "20,000.00 20,000.50 0.00 05/08/26 0.00 0.00 -0.50",
        "Emirates Islamic Bank (P.J.S.C.) is licensed by the Central Bank of the UAE.",
    ]
]

# ---------------------------------------------------------------- FAB
# Column layout (Debit/Credit by x position), a foreign row, a supplementary card, and a
# rewards redemption the summary's Payments/Credits column leaves out (DP-10), and the VAT row FAB
# prints under a foreign purchase with that purchase's currency and amount (an AED line, 2026.10.7).

_DEBIT_X, _CREDIT_X = 470, 530


def _fab_row(dates: str, description: str, original: str, aed: str, *, credit: bool = False) -> Line:
    return [(30, f"{dates} {description}"), (330, original), (_CREDIT_X if credit else _DEBIT_X, aed)]


_FAB_PAGES: list[list[Line]] = [
    [
        "MS JANE Q SAMPLE Main Card Product Statement Date Payment Due Date",
        # The address column shares the product line (real layout): "12 SAMPLE TOWER" is not the product.
        "12 SAMPLE TOWER SAMPLE CASHBACK CARD 01-02-2026 26-02-2026",
        "Main Card Number Current Balance Minimum Payment Due",
        "4000 12** **** 2468 1,000.92 100.00",
        "Summary Details",
        "Previous Balance + Purchases/Debits + Cash Advances + Finance Charges - Payments/Credits Total Payment Due",
        "1,500.00 1,200.92 0.00 0.00 1,500.00 1,000.92",
        "Total Credit Limit Available Credit Limit",
        "25,000.00 23,999.08",
        "Transaction Details",
        [(30, "Date"), (80, "Date"), (330, "Amount"), (_DEBIT_X, "Debit"), (_CREDIT_X, "Credit")],
        "Main Card : 4000 12** **** 2468 SAMPLE CASHBACK CARD",
        _fab_row("03-01-2026 03-01-2026", "CORNER GROCERY Dubai ARE", "AED 700.00", "700.00"),
        _fab_row("05-01-2026 05-01-2026", "ONLINE SHOP Dublin IRL", "USD 100.00", "367.50"),
        _fab_row("05-01-2026 05-01-2026", "VAT ON SERVICE CHARGES", "USD 100.00", "0.92"),
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


# ---------------------------------------------------------------- WIO
# "Credit Statement": signed AED rows, a foreign purchase with its rate line and separate
# FX fee row, a payment to another bank's card (no card number) and the bank's repayment.

_WIO_PAGES: list[list[Line]] = [
    [
        "CURRENCY MONTHLY INTEREST RATE ANNUAL INTEREST RATE",
        "CREDIT STATEMENT",
        "AED 3.25% 39.00%",
        "FROM 28/12/2025 TO 28/01/2026",
        "CREDIT LIMIT AVAILABLE CREDIT LIMIT TOT. INTEREST AND FEES",
        "20,000.00 19,500.00 0.00",
        "Jane Quincy PAYMENT DUE DATE MIN. PAYMENT DUE TOTAL TO PAY",
        "Sample 28/01/2026 25.00 500.00",
        "ACCOUNT NUMBER 1234567890",
        "Account summary",
        "Balance From Last Statement 100.00",
        "Purchases +1,325.00",
        "Interest +0.00",
        "Late payment fee +0.00",
        "Foreign exchange charges +2.00",
        "Payments and credits -1,027.00",
        "Closing balance (Total to pay) 400.00",
        "Transactions",
        "Date Ref. Number Description Card Number Amount",
        "02/01/2026 P100000001 Corner Grocery ****1234 -125.00",
        "05/01/2026 P100000002 Online Shop ****1234 -100.00",
        "Rate: 3.70 (AED/USD)",
        "05/01/2026 P100000002 Foreign Exchange Fee ****1234 -2.00",
        "Page 1 of 2",
        "(c) 2026 Wio, PJSC. All Rights Reserved.",
    ],
    [
        "Date Ref. Number Description Card Number Amount",
        "10/01/2026 P100000003 Sample Bank payment -1,100.00",
        "12/01/2026 P100000004 Book Shop ****1234 +27.00",
        "20/01/2026 P100000005 Credit Repayment +1,000.00",
        "Page 2 of 2",
        "(c) 2026 Wio, PJSC. All Rights Reserved.",
    ],
]


# ---------------------------------------------------------------- ADCB consolidated
# The monthly "Consolidated Statement of Accounts" (bank accounts, deposits, card summary).
# Columns sit at the real statement's x positions; a description wraps over the lines above
# and below its row's date, and a spacer line separates rows as the real row spacing does.
# Page 3 continues the current account without repeating the column header.

_ACCOUNT_HEADER: Line = [(41, "Date"), (134, "Description"), (245, "Chq/Ref"), (274, "No."), (305, "Value"),
                         (326, "Date"), (375, "Debit"), (448, "Credit"), (534, "Balance")]


def _account_details(number: str, product: str) -> list[Line]:
    return [
        [(24, f"Account Details: {number} - {product}"), (424, "Currency: AED")],
        [(24, f"IBAN: AE0000300{number}"), (424, "Branch: IBD - SAMPLE BRANCH")],
        [(24, "Account Title: JANE Q SAMPLE")],
        _ACCOUNT_HEADER,
    ]


_ADCB_CONSOLIDATED_PAGES: list[list[Line]] = [
    [
        "Consolidated Statement of Accounts",
        "JANE Q SAMPLE",
        "Customer ID: 99990001 Branch: SAMPLE BRANCH",
        "Summary of Accounts as on 30/09/2026",
        "Savings/Current/Call Accounts",
        "Account Number Account Description Currency Balance Balance (AED)",
        "99990001310001 Islamic Active Saver Account AED 1,012.40 1,012.40",
        "99990001320001 Islamic Current Account Personal AED 4,161.92 4,161.92",
        "Total 5,174.32",
        "Fixed Deposits/Market Linked Accounts",
        "Account Number Account Description Currency *Interest rate (%) p.a. Maturity Date Amount Amount (AED)",
        "99990001340001 ADCB Online Century Deposit AED 2.00 01/04/2027 52,301.10 52,301.10",
        "Total 52,301.10",
        "* Fixed interest rate (%) per.annum.",
        "Credit Cards",
        "Card Number Credit Limit Current Balance Payment Due Date",
        "xxxxxxxxxxxx1234 10,000 250.00 25.00 250.00 24/09/2026 19/10/2026",
        "TouchPoints Rewards Summary as on 30/09/2026",
        [(520, "Page 1 of 3")],
    ],
    [
        "Consolidated Statement of Accounts",
        "Transactions Details for the period from 01/09/2026 to 30/09/2026",
        *_account_details("99990001310001", "Islamic Active Saver Account"),
        [(26, "01/09/2026"), (76, "B/F ..."), (545, "1,000.00")],
        [],
        [(26, "30/09/2026"), (76, "PROFIT CREDIT"), (255, "100001"), (306, "30/09/2026"), (455, "12.40"),
         (545, "1,012.40")],
        [(76, "Total"), (380, "0.00"), (455, "12.40")],
        [],
        *_account_details("99990001320001", "Islamic Current Account Personal"),
        [(26, "01/09/2026"), (76, "B/F ..."), (545, "5,000.00")],
        [],
        [(76, "PUR 10/09 SAMPLE MART DUBAI")],
        [(26, "12/09/2026"), (255, "200001"), (306, "10/09/2026"), (380, "85.50"), (545, "4,914.50")],
        [(76, "5678")],
        [],
        [(76, "FOREIGN TRANSACTION FEE 11/09 0 784")],
        [(26, "14/09/2026"), (255, "200002"), (306, "11/09/2026"), (380, "2.08"), (545, "4,912.42")],
        [(76, "SAMPLE.COM5678")],
        [],
        [(26, "15/09/2026"), (76, "IPP TRANSFER TO J SAMPLE 4401"), (255, "200003"), (306, "15/09/2026"),
         (380, "1,250.00"), (545, "3,662.42")],
        [(520, "Page 2 of 3")],
    ],
    [
        "Consolidated Statement of Accounts",
        [(26, "28/09/2026"), (76, "INWARD REMITTANCE SAMPLE CO"), (255, "200004"), (306, "28/09/2026"),
         (455, "500.00"), (545, "4,162.42")],
        [],
        [(26, "29/09/2026"), (76, "SERVICE CHARGES"), (255, "200005"), (306, "29/09/2026"), (380, "0.50"),
         (545, "4,161.92")],
        [(76, "Total"), (380, "1,338.08"), (455, "500.00")],
        [(254, "End Of Statement")],
        [(520, "Page 3 of 3")],
    ],
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
    "enbd_fx_and_charges": Case(
        _ENBD_FX_PAGES,
        password=PASSWORD,
        settings={"ENBD_PDF_PASSWORD": PASSWORD},
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
    "eib_card_account": Case(
        _EIB_CARD_ACCOUNT_PAGES,
        password=PASSWORD,
        settings={"EIB_PDF_PASSWORD": PASSWORD},
        bank_code_hint="EIB",
    ),
    "eib_card_account_quiet": Case(
        _EIB_CARD_ACCOUNT_QUIET_PAGES,
        password=PASSWORD,
        settings={"EIB_PDF_PASSWORD": PASSWORD},
        bank_code_hint="EIB",
    ),
    "fab_statement": Case(_FAB_PAGES),
    "adcb_encrypted": Case(_ADCB_PAGES, password=PASSWORD, settings={"ADCB_PDF_PASSWORD": PASSWORD}),
    # The consolidated statement opens with the customer ID even when a card password is also set.
    "adcb_consolidated": Case(
        _ADCB_CONSOLIDATED_PAGES,
        password=PASSWORD,
        settings={"ADCB_CID": PASSWORD, "ADCB_PDF_PASSWORD": "another-card-password"},
        bank_code_hint="ADCB",
    ),
    "sib_history": Case(_SIB_HISTORY_PAGES),
    "sib_history_new_card": Case(_SIB_HISTORY_NEW_CARD_PAGES),
    # SRV-17: a wrong hint (an ADCB hint on a FAB PDF) is detected and retried once.
    "fab_wrong_hint": Case(_FAB_PAGES, bank_code_hint="ADCB"),
    "wio_statement": Case(_WIO_PAGES),
}
