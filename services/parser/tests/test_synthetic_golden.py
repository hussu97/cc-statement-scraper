"""Synthetic golden set: runs everywhere, including CI (SRV-24), and pins PARSER_VERSION (NEW-2).

``test_golden_parity.py`` checks the real (private, local-only) corpus against the legacy
parser. This suite checks fictional statements against committed snapshots, so a change in
parser output shows up in review as a JSON diff and needs a ``PARSER_VERSION`` bump.
"""

from __future__ import annotations

import json
import tomllib
from pathlib import Path

import pytest

from ccs_parser import PARSER_VERSION
from ccs_parser.contract import ParseResponse
from tests.synthetic.cases import CASES
from tests.synthetic.golden import digest, dump, load_expected, load_versions, run_all, run_case

UPDATE_HINT = (
    "Parser output changed. If intended: bump PARSER_VERSION (ccs_parser/__init__.py and pyproject.toml), "
    "run `PARSER_ISOLATION=inline .venv/bin/python -m tests.synthetic.update` and commit the snapshot diff."
)


@pytest.fixture(scope="module")
def expected() -> dict[str, dict]:
    return load_expected()


@pytest.mark.parametrize("name", sorted(CASES))
def test_case_matches_snapshot(name: str, expected: dict[str, dict], tmp_path: Path) -> None:
    assert name in expected, f"no snapshot for {name}. {UPDATE_HINT}"
    actual = run_case(CASES[name], tmp_path)
    assert dump(actual) == dump(expected[name]), UPDATE_HINT
    if "error" not in actual:
        ParseResponse.model_validate({**actual, "parser_version": PARSER_VERSION})


def test_no_orphan_snapshots(expected: dict[str, dict]) -> None:
    assert set(expected) == set(CASES)


def test_snapshot_digest_matches_parser_version(expected: dict[str, dict]) -> None:
    """NEW-2: the snapshots are the recorded output of the current PARSER_VERSION.

    Changing a snapshot without a version bump leaves the recorded digest stale; recording a
    new digest under an already-released version is refused by ``update.py``.
    """
    versions = load_versions()
    assert PARSER_VERSION in versions, f"PARSER_VERSION {PARSER_VERSION} has no recorded digest. {UPDATE_HINT}"
    assert digest(expected) == versions[PARSER_VERSION], (
        f"The snapshots differ from what PARSER_VERSION {PARSER_VERSION} recorded. {UPDATE_HINT}"
    )
    assert list(versions)[-1] == PARSER_VERSION, "versions.json must end with the current PARSER_VERSION"


def test_run_is_deterministic() -> None:
    assert digest(run_all()) == digest(run_all())


def test_pyproject_version_is_parser_version() -> None:
    """The deploy smoke test compares /health's parser_version with pyproject's version."""
    pyproject = tomllib.loads((Path(__file__).parents[1] / "pyproject.toml").read_text())
    assert pyproject["project"]["version"] == PARSER_VERSION


# "4000" is the synthetic BIN: the Mashreq parser reports the first four digits of
# "4000 XXXX XXXX 1234" (legacy behaviour, BACKLOG NEW-4).
SYNTHETIC_LAST4 = {"1234", "1357", "2222", "2468", "3333", "4000", "5678", "8765", "9876"}


def test_snapshots_hold_only_synthetic_cards(expected: dict[str, dict]) -> None:
    """Guard against pasting real statement data into the synthetic set."""
    seen: set[str] = set()
    for snapshot in expected.values():
        for st in snapshot.get("statements", []):
            seen.add(st["primary_card_last4"])
            seen.update(line["card_last4"] for line in st["lines"])
    assert seen - {None} <= SYNTHETIC_LAST4
    assert "SAMPLE" in json.dumps(expected)
