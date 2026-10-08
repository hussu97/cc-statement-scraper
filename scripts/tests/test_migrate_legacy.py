"""Pure parts of scripts/migrate_legacy.py: target guard (DP-13) and bank hint (SRV-09).

Run with the legacy backend venv (it has psycopg):
  backend/.venv/bin/python -m pytest -q scripts/tests
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
import types
from pathlib import Path

import pytest

if "psycopg" not in sys.modules:
    try:
        import psycopg  # noqa: F401
    except ImportError:  # the pure helpers don't need it
        sys.modules["psycopg"] = types.SimpleNamespace(Connection=object, connect=None)  # type: ignore[assignment]

_spec = importlib.util.spec_from_file_location("migrate_legacy", Path(__file__).resolve().parents[1] / "migrate_legacy.py")
ml = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ml)  # type: ignore[union-attr]

REF = ml.PROD_REF
LOCAL_DB = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
PROD_POOLER = f"postgresql://postgres.{REF}:pw@aws-0-eu-central-1.pooler.supabase.com:5432/postgres"
PROD_DIRECT = f"postgresql://postgres:pw@db.{REF}.supabase.co:5432/postgres"


def test_local_target_accepts_only_local_hosts() -> None:
    assert ml.check_target("local", LOCAL_DB, "http://127.0.0.1:54321") == []
    assert ml.check_target("local", LOCAL_DB, None) == []
    assert ml.check_target("local", PROD_POOLER, "http://127.0.0.1:54321")  # DB is prod
    assert ml.check_target("local", LOCAL_DB, f"https://{REF}.supabase.co")  # .env.cutover's URL


def test_prod_target_requires_the_prod_ref_everywhere() -> None:
    assert ml.check_target("prod", PROD_POOLER, f"https://{REF}.supabase.co") == []
    assert ml.check_target("prod", PROD_DIRECT, None) == []
    assert ml.check_target("prod", LOCAL_DB, f"https://{REF}.supabase.co")
    assert ml.check_target("prod", PROD_POOLER, "https://otherref.supabase.co")
    other = "postgresql://postgres.otherref:pw@aws-0-eu-central-1.pooler.supabase.com:5432/postgres"
    assert ml.check_target("prod", other, None)


def test_prod_write_confirmation() -> None:
    assert ml.confirm_prod_write(REF, interactive=False)
    assert not ml.confirm_prod_write("nope", interactive=True)
    assert not ml.confirm_prod_write(None, interactive=False)
    assert ml.confirm_prod_write(None, interactive=True, prompt=lambda _p: f" {REF} ")
    assert not ml.confirm_prod_write(None, interactive=True, prompt=lambda _p: "yes")


def _args(**kw) -> argparse.Namespace:
    return argparse.Namespace(**{"target": "prod", "apply": True, "yes_i_mean_prod": None, **kw})


def test_guard_refuses_prod_apply_without_confirmation(monkeypatch) -> None:
    monkeypatch.setenv("LEDGER_DB_URL", PROD_POOLER)
    monkeypatch.setenv("SUPABASE_URL", f"https://{REF}.supabase.co")
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False)
    with pytest.raises(SystemExit, match="refusing to write to production"):
        ml.guard_target(_args())
    ml.guard_target(_args(yes_i_mean_prod=REF))
    ml.guard_target(_args(apply=False))  # prod dry-run needs no confirmation


def test_guard_refuses_a_mismatched_environment(monkeypatch) -> None:
    monkeypatch.setenv("LEDGER_DB_URL", LOCAL_DB)
    monkeypatch.setenv("SUPABASE_URL", f"https://{REF}.supabase.co")
    with pytest.raises(SystemExit, match="refusing to run with --target local"):
        ml.guard_target(_args(target="local", apply=False))


@pytest.mark.parametrize(
    ("codes", "expected"),
    [(["FAB"], "FAB"), (["enbd", "ENBD"], "ENBD"), (["FAB", "ADCB"], None), ([], None), ([None], None), (["XYZ"], None)],
)
def test_legacy_bank_hint(codes, expected) -> None:
    assert ml.legacy_bank_hint(codes) == expected


def test_target_is_a_required_argument(monkeypatch) -> None:
    monkeypatch.setattr(sys, "argv", ["migrate_legacy.py", "--step", "metadata"])
    with pytest.raises(SystemExit):
        ml.main()
