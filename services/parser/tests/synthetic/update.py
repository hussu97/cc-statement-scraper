"""Regenerate the synthetic golden snapshots.

    cd services/parser && PARSER_ISOLATION=inline .venv/bin/python -m tests.synthetic.update

Refuses to change any snapshot while ``PARSER_VERSION`` is a version already recorded in
``versions.json`` with a different digest: bump ``PARSER_VERSION`` (``ccs_parser/__init__.py``
and ``pyproject.toml``) first, so ``documents.parser_version`` tells the old output from the
new (NEW-2). Review the JSON diff before committing it.
"""

from __future__ import annotations

import sys

from ccs_parser import PARSER_VERSION
from tests.synthetic.golden import EXPECTED_DIR, VERSIONS_FILE, digest, dump, load_expected, load_versions, run_all


def main() -> int:
    results = run_all()
    new_digest = digest(results)
    versions = load_versions()
    recorded = versions.get(PARSER_VERSION)
    if recorded is not None and recorded != new_digest:
        print(
            f"Parser output changed but PARSER_VERSION {PARSER_VERSION} is already recorded with other output.\n"
            "Bump PARSER_VERSION in ccs_parser/__init__.py and pyproject.toml, then re-run.",
            file=sys.stderr,
        )
        return 1

    EXPECTED_DIR.mkdir(exist_ok=True)
    old = load_expected()
    for stale in set(old) - set(results):
        (EXPECTED_DIR / f"{stale}.json").unlink()
    changed = sorted(name for name in results if old.get(name) != results[name])
    for name in changed:
        (EXPECTED_DIR / f"{name}.json").write_text(dump(results[name]))
    versions[PARSER_VERSION] = new_digest
    VERSIONS_FILE.write_text(dump(versions))
    print(f"{len(changed)} snapshot(s) written; {PARSER_VERSION} -> {new_digest[:12]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
