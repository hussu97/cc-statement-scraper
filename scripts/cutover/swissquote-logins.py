#!/usr/bin/env python3
"""Write SWISSQUOTE_LOGINS (the swissquote-sync Edge secret) into an env file, never to the screen.

    uv run --with pdfplumber scripts/cutover/swissquote-logins.py \
        --card ~/path/swissquote-card-auth.pdf --profile prf_… \
        [--env-file supabase/functions/.env.production] [--currency USD] [--credentials-env FILE]

The Level-3 matrix card PDF (Swissquote's "card" with columns A–J and rows 1–10) becomes
{"a1": "…", …}. The username and password come from SQ_USERNAME / SQ_PASSWORD when set, else
from --credentials-env (an env file with SWISSQUOTE_USERNAME / SWISSQUOTE_PASSWORD, e.g. the
old finances scraper's .env), else they are asked for without echo. The line
SWISSQUOTE_LOGINS=… replaces any earlier one in the file; only a count is printed. Push it with scripts/cutover/set-edge-secrets.sh (a production
action: ask first, CLAUDE.md §11.1).
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
from pathlib import Path


def card_grid(pdf_path: Path) -> dict[str, str]:
    import pdfplumber

    with pdfplumber.open(pdf_path) as pdf:
        tables = pdf.pages[0].extract_tables() if pdf.pages else []
    if not tables or len(tables[0]) < 3:
        raise SystemExit(f"no card table in {pdf_path}")
    grid = tables[0]
    letters = [(c or "").strip().lower() for c in grid[1]][1:]
    cells: dict[str, str] = {}
    for row in grid[2:]:
        rid = (row[0] or "").strip()
        if not rid.isdigit():
            continue
        for i, letter in enumerate(letters, start=1):
            code = (row[i] or "").strip() if i < len(row) else ""
            if re.fullmatch(r"[a-j]", letter) and re.fullmatch(r"\d{2,8}", code):
                cells[f"{letter}{rid}"] = code
    if len(cells) < 10:
        raise SystemExit(f"only {len(cells)} card cells read from {pdf_path}")
    return cells


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--card", type=Path, required=True)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--env-file", type=Path, default=Path("supabase/functions/.env.production"))
    ap.add_argument("--currency", default="USD")
    ap.add_argument("--credentials-env", type=Path)
    a = ap.parse_args()
    if not re.fullmatch(r"prf_[0-9a-z]{26}", a.profile):
        raise SystemExit("--profile must be a profile_code (prf_…)")
    creds: dict[str, str] = {}
    if a.credentials_env:
        for ln in a.credentials_env.read_text().splitlines():
            k, sep, v = ln.partition("=")
            if sep and k.strip() in ("SWISSQUOTE_USERNAME", "SWISSQUOTE_PASSWORD"):
                creds[k.strip()] = v.strip().strip('"').strip("'")
    username = os.environ.get("SQ_USERNAME") or creds.get("SWISSQUOTE_USERNAME") or input("Swissquote username: ").strip()
    password = os.environ.get("SQ_PASSWORD") or creds.get("SWISSQUOTE_PASSWORD") or getpass.getpass("Swissquote password: ")
    cells = card_grid(a.card)
    value = json.dumps([{"profile_code": a.profile, "username": username, "password": password,
                         "card": cells, "currency": a.currency.upper()}], separators=(",", ":"))
    lines = a.env_file.read_text().splitlines() if a.env_file.exists() else []
    lines = [ln for ln in lines if not ln.startswith("SWISSQUOTE_LOGINS=")]
    lines.append(f"SWISSQUOTE_LOGINS={value}")
    a.env_file.write_text("\n".join(lines) + "\n")
    print(f"wrote SWISSQUOTE_LOGINS to {a.env_file} (1 login, {len(cells)} card cells)")


if __name__ == "__main__":
    main()
