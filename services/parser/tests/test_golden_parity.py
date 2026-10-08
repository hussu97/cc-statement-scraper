"""Golden parity: the new service must reproduce the legacy backend parser.

Golden files are produced by ``scripts/build_golden.py`` (gitignored, private data).
The test is skipped when ``tests/golden/`` is empty.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.kinds import map_kind
from ccs_parser.service import money, money_or_none, parse_document

GOLDEN_DIR = Path(__file__).parent / "golden"
GOLDEN_FILES = sorted(GOLDEN_DIR.glob("*.json")) if GOLDEN_DIR.exists() else []

# Lines where legacy said "fee" and the whole-word classifier says "purchase"
# (e.g. "COFFEE", "RECHARGE"). The only kind difference allowed vs legacy.
# Reported in the terminal summary by conftest.py.
KIND_FEE_TO_PURCHASE: dict[str, int] = {}

pytestmark = pytest.mark.skipif(not GOLDEN_FILES, reason="no golden files; run scripts/build_golden.py")


def _load(path: Path) -> dict:
    return json.loads(path.read_text())


def _ok_golden() -> list[Path]:
    return [p for p in GOLDEN_FILES if _load(p)["status"] == "ok"]


def _failed_golden() -> list[Path]:
    return [p for p in GOLDEN_FILES if _load(p)["status"] != "ok"]


def _id(path: Path) -> str:
    # sha256 prefix only -- never put file names of private statements in test ids.
    return path.stem[:12]


@pytest.mark.parametrize("golden_path", _ok_golden(), ids=_id)
def test_golden_parity(golden_path: Path) -> None:
    golden = _load(golden_path)
    source = Path(golden["source_path"])
    if not source.exists():
        pytest.skip("source PDF no longer present")

    result = parse_document(source, filename=golden["filename"], settings=golden["settings"])

    assert result["bank_code"] == golden["bank_code"]
    expected_statements = golden["statements"]
    assert len(result["statements"]) == len(expected_statements), "statement count"

    for st_new, st_old in zip(result["statements"], expected_statements, strict=True):
        assert st_new["statement_date"] == st_old["statement_date"]
        assert st_new["statement_reference"] == st_old["statement_reference"]
        assert st_new["reference_source"] == st_old["reference_source"]
        assert st_new["period_start"] == st_old["period_start"]
        assert st_new["period_end"] == st_old["period_end"]
        expected_kind = "history_extract" if st_old["pdf_type"] == "transaction_history" else "statement"
        assert st_new["kind"] == expected_kind
        assert len(st_new["lines"]) == len(st_old["lines"]), "line count"

        for ln_new, ln_old in zip(st_new["lines"], st_old["lines"], strict=True):
            ctx = f"line {ln_old['line_no']}"
            assert ln_new["line_no"] == ln_old["line_no"], ctx
            assert ln_new["txn_date"] == ln_old["txn_date"], ctx
            assert ln_new["posting_date"] == ln_old["posting_date"], ctx
            assert ln_new["amount_original"] == money(ln_old["amount_original"]), ctx
            assert ln_new["amount_aed"] == money_or_none(ln_old["amount_aed"]), ctx
            assert ln_new["direction"] == ln_old["direction"], ctx
            assert ln_new["currency_original"] == ln_old["currency_original"], ctx
            assert ln_new["description_raw"] == ln_old["merchant_raw"], ctx
            assert ln_new["merchant_normalized"] == ln_old["merchant_normalized"], ctx
            assert ln_new["legacy_fingerprint"] == ln_old["fingerprint"], ctx

            expected_kind = map_kind(ln_old["kind"], ln_old["merchant_normalized"], ln_old["direction"])
            if ln_new["kind"] != expected_kind:
                assert (ln_old["kind"], ln_new["kind"]) == ("fee", "purchase"), ctx
                KIND_FEE_TO_PURCHASE[golden_path.stem] = KIND_FEE_TO_PURCHASE.get(golden_path.stem, 0) + 1


@pytest.mark.parametrize("golden_path", _failed_golden(), ids=_id)
def test_legacy_failures_still_fail_cleanly(golden_path: Path) -> None:
    """PDFs the legacy parser could not handle must fail with a classified ParserError."""
    golden = _load(golden_path)
    source = Path(golden["source_path"])
    if not source.exists():
        pytest.skip("source PDF no longer present")
    with pytest.raises(ParserError) as exc:
        parse_document(source, filename=golden["filename"], settings=golden["settings"])
    assert exc.value.code in {"PDF_DECRYPT_FAILED", "BANK_UNDETECTED", "UNSUPPORTED_LAYOUT", "UNSUPPORTED_BANK"}
