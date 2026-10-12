"""Run the synthetic cases and compare them with the committed snapshots (SRV-24, NEW-2).

``expected/<case>.json`` is the parser's output for each case, without ``parser_version``.
``versions.json`` maps each ``PARSER_VERSION`` to the digest of the whole snapshot set, so
the output of a released version can't change silently: a snapshot change under an
unchanged ``PARSER_VERSION`` fails ``test_snapshot_digest_matches_parser_version``.
"""

from __future__ import annotations

import hashlib
import json
import tempfile
from pathlib import Path
from typing import Any

from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.service import parse_document
from tests.synthetic.cases import CASES, Case

HERE = Path(__file__).parent
EXPECTED_DIR = HERE / "expected"
VERSIONS_FILE = HERE / "versions.json"
SHA_PLACEHOLDER = "<pdf_sha256>"


def _scrub_sha(value: Any, sha: str) -> Any:
    """Encryption salts make encrypted PDFs differ byte-wise per run: hide their checksum."""
    text = json.dumps(value)
    for token in (sha, sha[:12], sha[:12].upper()):
        text = text.replace(token, SHA_PLACEHOLDER)
    return json.loads(text)


def run_case(case: Case, workdir: Path) -> dict[str, Any]:
    """The parser's output for ``case`` (or its error), without ``parser_version``."""
    pdf = case.write(workdir / case.filename)
    sha = hashlib.sha256(pdf.read_bytes()).hexdigest()
    try:
        out = parse_document(pdf, filename=case.filename, bank_code_hint=case.bank_code_hint, settings=case.settings)
    except ParserError as exc:
        return {"error": {"code": exc.code, "message": str(exc)}}
    out.pop("parser_version")
    return _scrub_sha(out, sha) if case.password else out


def run_all() -> dict[str, dict[str, Any]]:
    with tempfile.TemporaryDirectory() as tmp:
        results = {}
        for name, case in CASES.items():
            workdir = Path(tmp) / name
            workdir.mkdir()
            results[name] = run_case(case, workdir)
        return results


def load_expected() -> dict[str, dict[str, Any]]:
    return {p.stem: json.loads(p.read_text()) for p in sorted(EXPECTED_DIR.glob("*.json"))}


def digest(snapshots: dict[str, dict[str, Any]]) -> str:
    canonical = json.dumps(snapshots, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def load_versions() -> dict[str, str]:
    return json.loads(VERSIONS_FILE.read_text()) if VERSIONS_FILE.exists() else {}


def dump(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def dump_versions(versions: dict[str, str]) -> str:
    """versions.json in release order: sorting would put "2026.10.10" before "2026.10.2"."""
    return json.dumps(versions, indent=2, ensure_ascii=True) + "\n"
