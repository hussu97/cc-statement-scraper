"""Golden parity: the new service must reproduce the legacy backend parser.

Golden files are produced by ``scripts/build_golden.py`` (gitignored, private data).
The test is skipped when ``tests/golden/`` is empty.
"""

from __future__ import annotations

import json
from datetime import date
from decimal import Decimal
from pathlib import Path

import pytest

from ccs_parser.contract import MAX_STATEMENT_PERIOD_DAYS
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.kinds import map_kind
from ccs_parser.service import money, money_or_none, parse_document

GOLDEN_DIR = Path(__file__).parent / "golden"
GOLDEN_FILES = sorted(GOLDEN_DIR.glob("*.json")) if GOLDEN_DIR.exists() else []

# Lines where legacy said "fee" and the whole-word classifier says "purchase"
# (e.g. "COFFEE", "RECHARGE"). The only kind difference allowed vs legacy.
# Reported in the terminal summary by conftest.py.
KIND_FEE_TO_PURCHASE: dict[str, int] = {}

# Documented improvements over legacy (the only other differences allowed), reported
# by conftest.py:
#   * DP-03/04: ENBD prints the wrong year at the Dec/Jan boundary; legacy kept it.
#   * DP-07: FAB rows whose original amount is "KWD 18.750" / "EUR 108,99" were
#     skipped by legacy; they are accepted only if they make the debits reconcile.
ALLOWED_DELTAS: dict[str, set[str]] = {
    "period year corrected (DP-03/04)": set(),
    "rows legacy skipped (DP-07)": set(),
}
RECOVERED_LINES: dict[str, int] = {}

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


def _legacy_period_impossible(st_old: dict) -> bool:
    """Legacy's period breaks the DB/contract rules (ENBD's misprinted Dec/Jan years, DP-03/04)."""
    if not (st_old["period_start"] and st_old["period_end"]):
        return False
    start, end = date.fromisoformat(st_old["period_start"]), date.fromisoformat(st_old["period_end"])
    return start > end or (end - start).days > MAX_STATEMENT_PERIOD_DAYS


def _assert_year_corrected(st_new: dict, st_old: dict) -> None:
    """Allowed delta 1: the year is re-derived; day and month must not change."""
    new_start, new_end = date.fromisoformat(st_new["period_start"]), date.fromisoformat(st_new["period_end"])
    old_start, old_end = date.fromisoformat(st_old["period_start"]), date.fromisoformat(st_old["period_end"])
    assert (new_start.month, new_start.day) == (old_start.month, old_start.day)
    assert (new_end.month, new_end.day) == (old_end.month, old_end.day)
    assert new_start <= new_end and (new_end - new_start).days <= MAX_STATEMENT_PERIOD_DAYS
    assert st_new["statement_date"] == st_new["period_end"]
    assert st_new["reference_source"] == st_old["reference_source"]
    if st_old["reference_source"] == "fallback":
        expected_ref = st_old["statement_reference"].replace(st_old["statement_date"], st_new["statement_date"])
        assert st_new["statement_reference"] == expected_ref
    else:
        assert st_new["statement_reference"] == st_old["statement_reference"]


def _debits(lines: list[dict], amount_key: str) -> Decimal:
    return sum((Decimal(str(abs(float(ln[amount_key])))) for ln in lines if ln["direction"] == "debit"), Decimal(0))


def _pair_lines(st_new: dict, st_old: dict) -> tuple[list[tuple[dict, dict]], list[dict]]:
    """Match legacy lines (in order, by fingerprint) inside the new lines; return pairs and extras."""
    pairs: list[tuple[dict, dict]] = []
    extras: list[dict] = []
    old_lines = st_old["lines"]
    j = 0
    for ln_new in st_new["lines"]:
        if j < len(old_lines) and ln_new["legacy_fingerprint"] == old_lines[j]["fingerprint"]:
            pairs.append((ln_new, old_lines[j]))
            j += 1
        else:
            extras.append(ln_new)
    assert j == len(old_lines), "a legacy line is missing from the new output"
    return pairs, extras


def _assert_recovered_lines(st_new: dict, st_old: dict, extras: list[dict]) -> None:
    """Allowed delta 2: rows legacy skipped (DP-07). Only accepted when they close the gap
    between the statement's own debit total and the parsed debits."""
    total = st_new["totals"]["total_debits"]
    assert total is not None, "extra lines on a statement without a debit total"
    assert _debits(st_new["lines"], "amount_aed") == Decimal(total), "extra lines do not reconcile debits"
    assert _debits(st_old["lines"], "amount_aed") != Decimal(total), "legacy already reconciled"
    assert all(ln["direction"] == "debit" for ln in extras)


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
        if _legacy_period_impossible(st_old):
            _assert_year_corrected(st_new, st_old)
            ALLOWED_DELTAS["period year corrected (DP-03/04)"].add(golden_path.stem)
        else:
            assert st_new["statement_date"] == st_old["statement_date"]
            assert st_new["statement_reference"] == st_old["statement_reference"]
            assert st_new["reference_source"] == st_old["reference_source"]
            assert st_new["period_start"] == st_old["period_start"]
            assert st_new["period_end"] == st_old["period_end"]
        expected_kind = "history_extract" if st_old["pdf_type"] == "transaction_history" else "statement"
        assert st_new["kind"] == expected_kind

        pairs, extras = _pair_lines(st_new, st_old)
        if extras:
            _assert_recovered_lines(st_new, st_old, extras)
            ALLOWED_DELTAS["rows legacy skipped (DP-07)"].add(golden_path.stem)
            RECOVERED_LINES[golden_path.stem] = len(extras)

        for ln_new, ln_old in pairs:
            ctx = f"line {ln_old['line_no']}"
            if not extras:
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
