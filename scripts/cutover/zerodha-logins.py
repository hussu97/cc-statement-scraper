#!/usr/bin/env python3
"""Write ZERODHA_LOGINS (the zerodha-sync Edge secret) into an env file, never to the screen.

    python3 scripts/cutover/zerodha-logins.py --profile prf_… \
        [--env-file supabase/functions/.env.production]

Asks for the Kite user id and API key, and (without echo) the password, the TOTP seed (the base32
key shown when 2FA was set up, "Can't scan? Copy the key") and the Kite Connect API secret. Each
can come from the environment instead: KITE_USER_ID, KITE_PASSWORD, KITE_TOTP_SECRET,
KITE_API_KEY, KITE_API_SECRET. The login is added to the file's ZERODHA_LOGINS (one per profile;
the profile's earlier login is replaced) and only a count is printed. Push it with
scripts/cutover/set-edge-secrets.sh (a production action: ask first, CLAUDE.md §11.1).
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
from pathlib import Path


def ask(env: str, prompt: str, secret: bool) -> str:
    v = os.environ.get(env) or (getpass.getpass(prompt) if secret else input(prompt))
    return v.strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True)
    ap.add_argument("--env-file", type=Path, default=Path("supabase/functions/.env.production"))
    a = ap.parse_args()
    if not re.fullmatch(r"prf_[0-9a-z]{26}", a.profile):
        raise SystemExit("--profile must be a profile_code (prf_…)")
    user_id = ask("KITE_USER_ID", "Kite user id: ", False).upper()
    password = ask("KITE_PASSWORD", "Kite password: ", True)
    seed = re.sub(r"[\s=]", "", ask("KITE_TOTP_SECRET", "TOTP seed (base32): ", True)).upper()
    api_key = ask("KITE_API_KEY", "Kite Connect API key: ", False)
    api_secret = ask("KITE_API_SECRET", "Kite Connect API secret: ", True)
    if not re.fullmatch(r"[A-Z0-9]{4,12}", user_id):
        raise SystemExit("the user id is 4–12 letters and digits")
    if not password:
        raise SystemExit("a password is required")
    if not re.fullmatch(r"[A-Z2-7]{16,}", seed):
        raise SystemExit("the TOTP seed is base32 (A–Z, 2–7), at least 16 characters")
    if not re.fullmatch(r"[A-Za-z0-9]{6,64}", api_key) or not re.fullmatch(r"[A-Za-z0-9]{6,128}", api_secret):
        raise SystemExit("the API key and secret are letters and digits")

    lines = a.env_file.read_text().splitlines() if a.env_file.exists() else []
    logins: list[dict[str, str]] = []
    for ln in lines:
        if ln.startswith("ZERODHA_LOGINS="):
            try:
                logins = json.loads(ln.partition("=")[2])
            except json.JSONDecodeError:
                raise SystemExit(f"ZERODHA_LOGINS in {a.env_file} is not JSON: fix or remove it")
    logins = [x for x in logins if x.get("profile_code") != a.profile]
    logins.append({"profile_code": a.profile, "user_id": user_id, "password": password, "totp_secret": seed,
                   "api_key": api_key, "api_secret": api_secret})
    lines = [ln for ln in lines if not ln.startswith("ZERODHA_LOGINS=")]
    lines.append("ZERODHA_LOGINS=" + json.dumps(logins, separators=(",", ":")))
    a.env_file.write_text("\n".join(lines) + "\n")
    print(f"wrote ZERODHA_LOGINS to {a.env_file} ({len(logins)} login{'s' if len(logins) != 1 else ''})")


if __name__ == "__main__":
    main()
