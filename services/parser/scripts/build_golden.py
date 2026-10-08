#!/usr/bin/env python
"""Build golden parity fixtures by running the LEGACY backend parser.

Walks a directory of PDFs, de-duplicates them by SHA-256, runs the legacy
``backend/ccs_platform`` parser (bank detection + ``parse_statement_pdf`` +
``resolve_statement_identity``) in a subprocess using the backend's own
virtualenv, and writes one JSON file per unique PDF into ``tests/golden/``.

The golden directory is gitignored: it contains private statement data.

Usage (from services/parser):
    .venv/bin/python scripts/build_golden.py [--pdf-dir DIR] [--out DIR]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from collections import Counter
from pathlib import Path

SERVICE_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SERVICE_DIR.parents[1]
DEFAULT_PDF_DIR = REPO_ROOT / "data" / "archive"
DEFAULT_OUT_DIR = SERVICE_DIR / "tests" / "golden"
BACKEND_DIR = REPO_ROOT / "backend"
BACKEND_PYTHON = BACKEND_DIR / ".venv" / "bin" / "python"
RUNNER = Path(__file__).resolve().parent / "_legacy_runner.py"

# Archive PDFs are already-decrypted copies. ADCB and SIB statement parsers refuse
# to run without a password, so pass a dummy one (ignored for unencrypted PDFs).
# The parity test replays exactly these settings against the new parser.
GOLDEN_SETTINGS = {
    "ADCB_PDF_PASSWORD": "golden-dummy-password",
    "SIB_PDF_PASSWORD": "golden-dummy-password",
}


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect_unique_pdfs(pdf_dir: Path) -> tuple[int, list[dict]]:
    all_pdfs = sorted(p for p in pdf_dir.rglob("*") if p.is_file() and p.suffix.lower() == ".pdf")
    unique: dict[str, Path] = {}
    for path in all_pdfs:
        digest = _sha256(path)
        unique.setdefault(digest, path)  # first path in sorted order wins (deterministic)
    items = [{"path": str(p), "filename": p.name, "sha256": d} for d, p in sorted(unique.items())]
    return len(all_pdfs), items


def run_legacy(items: list[dict]) -> list[dict]:
    if not BACKEND_PYTHON.exists():
        sys.exit(f"Legacy backend interpreter not found at {BACKEND_PYTHON}")
    env = {**os.environ, "PYTHONPATH": str(BACKEND_DIR)}
    proc = subprocess.run(
        [str(BACKEND_PYTHON), str(RUNNER)],
        input=json.dumps({"settings": GOLDEN_SETTINGS, "items": items}),
        capture_output=True,
        text=True,
        env=env,
        cwd=str(BACKEND_DIR),
        check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-4000:])
        sys.exit(f"legacy runner failed with exit code {proc.returncode}")
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pdf-dir", type=Path, default=DEFAULT_PDF_DIR)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT_DIR)
    args = parser.parse_args()

    scanned, items = collect_unique_pdfs(args.pdf_dir)
    results = run_legacy(items)

    args.out.mkdir(parents=True, exist_ok=True)
    for stale in args.out.glob("*.json"):
        stale.unlink()
    for result in results:
        (args.out / f"{result['sha256']}.json").write_text(json.dumps(result, indent=2, sort_keys=True))

    by_status = Counter(r["status"] for r in results)
    ok_by_bank = Counter(r["bank_code"] for r in results if r["status"] == "ok")
    err_by_bank = Counter(
        f"{r['bank_code']}:{(r.get('error') or {}).get('code')}" for r in results if r["status"] == "error"
    )
    print(f"PDFs scanned: {scanned}")
    print(f"Unique PDFs:  {len(items)}")
    print(f"Status:       {dict(by_status)}")
    print(f"Parsed by bank: {dict(sorted(ok_by_bank.items()))}")
    if err_by_bank:
        print(f"Legacy errors:  {dict(sorted(err_by_bank.items()))}")
    print(f"Golden files written to {args.out}")


if __name__ == "__main__":
    main()
