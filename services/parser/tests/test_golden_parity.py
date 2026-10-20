"""Golden parity: the service must reproduce the legacy v1 backend parser.

The golden files in ``tests/golden/`` are a frozen snapshot of the legacy parser's output
(gitignored, private data), built before the legacy code was removed; they can't be
rebuilt from this repo. The test is skipped when ``tests/golden/`` is empty.
"""

from __future__ import annotations

import json
import re
import subprocess
from datetime import date
from decimal import Decimal
from pathlib import Path

import pytest

from ccs_parser.contract import MAX_STATEMENT_PERIOD_DAYS
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.kinds import map_kind
from ccs_parser.places import separate_glued_place
from ccs_parser.service import money, money_or_none, parse_document


def _golden_dir() -> Path:
    """This checkout's snapshots, or, in a linked worktree (which has none: they are gitignored),
    the main checkout's. A parser change made in a worktree skipped this test twice and failed
    the next push from the main checkout (lessons: "Golden parity is local-only")."""
    here = Path(__file__).parent / "golden"
    if here.exists():
        return here
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd=Path(__file__).parent,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return here
    main = Path(common).parent / "services" / "parser" / "tests" / "golden"
    return main if main.exists() else here


GOLDEN_DIR = _golden_dir()
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
#   * 2026.10.4: merchant_normalized separates a city glued to the merchant
#     ("SOCIETSHARJAH" -> "SOCIET SHARJAH"); description_raw and the fingerprint are unchanged.
#   * 2026.10.7: a FAB "VAT ON ..." row is an AED line; legacy kept the foreign purchase's
#     currency and amount that FAB prints beside it. amount_aed and the fingerprint are unchanged.
#   * 2026.10.10: an ENBD foreign row ("*RL360 DOUGLAS GBR 2,000.00 USD", then "(1 AED = USD
#     0.26398)") carries its original amount, currency and rate, and the description loses the
#     amount; the Credit Shield premium and "VAT ON ..." are fees. amount_aed and the fingerprint
#     are unchanged.
ALLOWED_DELTAS: dict[str, set[str]] = {
    "period year corrected (DP-03/04)": set(),
    "rows legacy skipped (DP-07)": set(),
    "glued place separated (2026.10.4)": set(),
    "FAB VAT row is AED (2026.10.7)": set(),
    "ENBD foreign row and bank charges (2026.10.10)": set(),
    "cash withdrawal is a cash advance (2026.10.20)": set(),
    "SIB history closes on the 14th (2026.10.15.1)": set(),
}
RECOVERED_LINES: dict[str, int] = {}

pytestmark = pytest.mark.skipif(not GOLDEN_FILES, reason="no golden files (frozen, local-only legacy snapshot)")


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


def _printed(amount: str) -> str:
    """An amount as ENBD prints it in a description: thousands separators, two places."""
    return f"{Decimal(amount):,.2f}"


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


def _assert_sib_history_rebucketed(new_statements: list[dict], old_statements: list[dict]) -> None:
    """Allowed delta: SIB history exports close on the 14th, not the 12th (parser 2026.10.15.1).
    Rows dated the 13th and 14th move to the next cycle, so statements no longer pair one to
    one: every row must still be there, unchanged, and every cycle must end on the 14th."""

    new_rows = sorted(
        (ln["txn_date"], ln["direction"], ln["amount_aed"]) for st in new_statements for ln in st["lines"]
    )
    old_rows = sorted(
        (ln["txn_date"], ln["direction"], money_or_none(ln["amount_aed"]))
        for st in old_statements
        for ln in st["lines"]
    )
    assert new_rows == old_rows, "SIB history rows changed beyond re-bucketing"
    for st in new_statements:
        assert st["kind"] == "history_extract"
        assert st["period_end"] is None or st["period_end"][8:] == "14", st["period_end"]


@pytest.mark.parametrize("golden_path", _ok_golden(), ids=_id)
def test_golden_parity(golden_path: Path) -> None:
    golden = _load(golden_path)
    source = Path(golden["source_path"])
    if not source.exists():
        pytest.skip("source PDF no longer present")

    result = parse_document(source, filename=golden["filename"], settings=golden["settings"])

    assert result["bank_code"] == golden["bank_code"]
    expected_statements = golden["statements"]
    if golden["bank_code"] == "SIB" and all(st["pdf_type"] == "transaction_history" for st in expected_statements):
        _assert_sib_history_rebucketed(result["statements"], expected_statements)
        ALLOWED_DELTAS["SIB history closes on the 14th (2026.10.15.1)"].add(golden_path.stem)
        return
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
            assert ln_new["amount_aed"] == money_or_none(ln_old["amount_aed"]), ctx
            assert ln_new["direction"] == ln_old["direction"], ctx
            enbd_foreign = (
                golden["bank_code"] == "ENBD"
                and ln_new["currency_original"] != "AED"
                and ln_old["merchant_raw"]
                == f"{ln_new['description_raw']} {_printed(ln_new['amount_original'])} {ln_new['currency_original']}"
            )
            if enbd_foreign:
                assert ln_old["currency_original"] == "AED", ctx
                assert ln_new["merchant_normalized"] != ln_old["merchant_normalized"], ctx
                ALLOWED_DELTAS["ENBD foreign row and bank charges (2026.10.10)"].add(golden_path.stem)
            elif ln_new["currency_original"] != ln_old["currency_original"]:
                assert golden["bank_code"] == "FAB" and ln_old["merchant_raw"].startswith("VAT "), ctx
                assert ln_new["currency_original"] == "AED", ctx
                assert ln_new["amount_original"] == ln_new["amount_aed"], ctx
                ALLOWED_DELTAS["FAB VAT row is AED (2026.10.7)"].add(golden_path.stem)
            else:
                assert ln_new["amount_original"] == money(ln_old["amount_original"]), ctx
            if not enbd_foreign:
                assert ln_new["description_raw"] == ln_old["merchant_raw"], ctx
            if not enbd_foreign and ln_new["merchant_normalized"] != ln_old["merchant_normalized"]:
                assert ln_new["merchant_normalized"] == separate_glued_place(ln_old["merchant_normalized"]), ctx
                ALLOWED_DELTAS["glued place separated (2026.10.4)"].add(golden_path.stem)
            assert ln_new["legacy_fingerprint"] == ln_old["fingerprint"], ctx

            expected_kind = map_kind(ln_old["kind"], ln_old["merchant_normalized"], ln_old["direction"])
            if ln_new["kind"] != expected_kind and golden["bank_code"] == "ENBD" and ln_new["kind"] == "fee":
                assert expected_kind == "purchase", ctx
                assert re.match(r"^(?:CREDIT SHIELD\b|VAT ON\b)", ln_old["merchant_raw"]), ctx
                ALLOWED_DELTAS["ENBD foreign row and bank charges (2026.10.10)"].add(golden_path.stem)
            elif (ln_old["kind"], ln_new["kind"]) == ("purchase", "cash_advance"):
                # 2026.10.20: an ATM / cash withdrawal, or the purchase a CASH ADVANCE FEE follows.
                fee_follows = any(
                    re.match(r"^CASH ADV(?:ANCE)? FEE\b", (x["merchant_normalized"] or "").upper())
                    for x in st_new["lines"]
                    if x["txn_date"] == ln_new["txn_date"]
                )
                atm = re.search(r"\bATM\b|\bCASH\s+(?:WITHDRAWAL|WDL)\b", (ln_new["merchant_normalized"] or "").upper())
                assert fee_follows or atm, ctx
                ALLOWED_DELTAS["cash withdrawal is a cash advance (2026.10.20)"].add(golden_path.stem)
            elif ln_new["kind"] != expected_kind:
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
