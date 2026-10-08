from __future__ import annotations

from datetime import date
from pathlib import Path

import pytest

from ccs_parser.domain.parsing.models import StatementParseResult, TransactionRecord
from ccs_parser.domain.parsing.utils import fingerprint_for, merchant_normalize


def make_tx(
    *,
    desc: str,
    amount_aed: float | None,
    amount_original: float | None = None,
    currency: str = "AED",
    kind: str = "purchase",
    posting: date = date(2026, 1, 10),
    last4: str = "1234",
    fx: float | None = 1.0,
) -> TransactionRecord:
    merchant = merchant_normalize(desc)
    original = amount_aed if amount_original is None else amount_original
    return TransactionRecord(
        bank_name="Test Bank",
        card_last4=last4,
        card_holder="JANE DOE",
        card_type="Credit Card",
        statement_month="2026-01",
        transaction_date=posting,
        posting_date=posting,
        merchant_raw=desc,
        merchant_normalized=merchant,
        country_code=None,
        amount_original=original,
        currency_original=currency,
        amount_aed=amount_aed,
        fx_rate_to_aed=fx,
        transaction_kind=kind,
        source_pdf="/tmp/x.pdf",
        fingerprint=fingerprint_for(
            "Test Bank", last4, posting, amount_aed if amount_aed is not None else original, merchant
        ),
    )


def make_result(
    transactions: list[TransactionRecord],
    *,
    bank_code: str = "ENBD",
    metadata: dict | None = None,
    statement_month: str = "2026-01",
) -> StatementParseResult:
    return StatementParseResult(
        bank_code=bank_code,
        bank_name="Test Bank",
        source_pdf=Path("/tmp/x.pdf"),
        statement_month=statement_month,
        transactions=transactions,
        warnings=[],
        metadata={"statement_date": "2026-01-28", "card_last4": "1234"} if metadata is None else metadata,
    )


@pytest.fixture
def pdf_file(tmp_path: Path) -> Path:
    path = tmp_path / "document.pdf"
    path.write_bytes(b"%PDF-1.4\n% fake test document\n")
    return path


def pytest_terminal_summary(terminalreporter) -> None:
    try:
        from tests.test_golden_parity import ALLOWED_DELTAS, KIND_FEE_TO_PURCHASE, RECOVERED_LINES
    except Exception:  # noqa: BLE001
        return
    for label, stems in ALLOWED_DELTAS.items():
        if stems:
            extra = f" ({sum(RECOVERED_LINES.get(s, 0) for s in stems)} lines)" if "DP-07" in label else ""
            terminalreporter.write_line(f"golden parity allowed delta: {label}: {len(stems)} PDFs{extra}")
    if KIND_FEE_TO_PURCHASE:
        terminalreporter.write_line(
            f"golden parity: {sum(KIND_FEE_TO_PURCHASE.values())} lines in {len(KIND_FEE_TO_PURCHASE)} PDFs "
            "changed kind fee -> purchase (whole-word fee classifier)"
        )
