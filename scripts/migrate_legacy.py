#!/usr/bin/env python3
"""Ledger v2 cutover: move legacy data into the v2 schema.

Run AFTER `supabase db push` has applied the v2 migrations to the project (the
first migration moves the legacy tables into the `legacy` schema).

Steps (each idempotent; dry-run unless --apply):
  1. metadata  – profiles, categories, rules, category choices, email config
                 (SQL: private.import_legacy_metadata)
  2. secrets   – Fernet-decrypt legacy runtime settings → Vault
                 (PDF passwords, mailbox OAuth refresh tokens)
  3. pdfs      – copy every legacy PDF (GCS or local storage) into Storage as
                 documents(source='legacy'); the worker re-parses them
  4. finalize  – after the worker has drained the queue: apply legacy category
                 choices and print the parity report

Only counts are printed — never secret values, statement contents or amounts
beyond per-month aggregates.

Usage (from repo root, using the legacy backend venv which has every dependency):
  backend/.venv/bin/python scripts/migrate_legacy.py --target local --step metadata \
      --members '{"alice":"h_abbasi97@hotmail.com","bob":"bob@example.com"}' [--apply]
  backend/.venv/bin/python scripts/migrate_legacy.py --target local --step secrets [--apply] [--functions-env-out F]
  backend/.venv/bin/python scripts/migrate_legacy.py --target local --step pdfs [--apply] [--limit N]
  backend/.venv/bin/python scripts/migrate_legacy.py --target local --step finalize [--apply]

Target guard (audit DP-13): `--target local|prod` is required and must match the
environment. `local` requires LEDGER_DB_URL (and SUPABASE_URL when used) on
127.0.0.1/localhost; `prod` requires both to name the production project ref
(PROD_REF below). `--apply` against prod also needs `--yes-i-mean-prod <ref>`, or
typing the ref at the prompt. Dry-run stays the default.

Environment:
  LEDGER_DB_URL                 postgres URL of the v2 project (session pooler, port 5432)
  SUPABASE_URL                  https://<ref>.supabase.co
  SUPABASE_SERVICE_ROLE_KEY     service role key (Storage upload)
  LEGACY_FERNET_KEY             legacy CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY (secrets step)
  LEGACY_STORAGE                gcs | local (default gcs)
  LEGACY_GCS_BUCKET             legacy bucket (gcs)
  GOOGLE_APPLICATION_CREDENTIALS service-account JSON with read access (gcs)
  LEGACY_LOCAL_ROOT             legacy local storage root (local), e.g. data/archive
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

import httpx
import psycopg

ENC_PREFIX = "enc:v1:"
# Production Supabase project (PRODUCTION.md). The only remote target this script accepts.
PROD_REF = "<project-ref>"
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}
SUPPORTED_BANKS = {"FAB", "ADCB", "ENBD", "EIB", "SIB", "MASHREQ"}
PDF_SECRET_KEY = re.compile(r"^(FAB|ADCB|ENBD|EIB|SIB|MASHREQ)_PDF_PASSWORD$|^ADCB_CID$")
MAILBOX_SECRET_KEY = re.compile(r"^EMAIL_(GMAIL|MS)_REFRESH_TOKEN_MAILBOX_(\d+)$")
# Legacy runtime setting -> Edge Function secret name. The targets must match exactly what
# supabase/functions/_shared/oauth.ts reads (`${GMAIL|MS}_OAUTH_CLIENT_{ID,SECRET}`).
APP_SECRET_KEYS = {
    "EMAIL_GMAIL_CLIENT_ID": "GMAIL_OAUTH_CLIENT_ID",
    "EMAIL_GMAIL_CLIENT_SECRET": "GMAIL_OAUTH_CLIENT_SECRET",
    "EMAIL_MS_CLIENT_ID": "MS_OAUTH_CLIENT_ID",
    "EMAIL_MS_CLIENT_SECRET": "MS_OAUTH_CLIENT_SECRET",
}


def env(name: str, required: bool = True) -> str:
    value = os.environ.get(name, "").strip()
    if required and not value:
        sys.exit(f"missing env {name}")
    return value


# ── target guard (DP-13) ─────────────────────────────────────────────────────
def _host(url: str) -> str:
    from urllib.parse import urlsplit

    try:
        return (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def _db_names_ref(db_url: str, ref: str) -> bool:
    """Direct host db.<ref>.supabase.co, or the pooler's user postgres.<ref>."""
    from urllib.parse import unquote, urlsplit

    parts = urlsplit(db_url)
    return _host(db_url) == f"db.{ref}.supabase.co" or unquote(parts.username or "").endswith(f".{ref}")


def check_target(target: str, db_url: str, supabase_url: str | None) -> list[str]:
    """Problems that make the environment disagree with --target (empty = OK)."""
    problems: list[str] = []
    if target == "local":
        if _host(db_url) not in LOCAL_HOSTS:
            problems.append(f"LEDGER_DB_URL host {_host(db_url) or '?'} is not local")
        if supabase_url and _host(supabase_url) not in LOCAL_HOSTS:
            problems.append(f"SUPABASE_URL host {_host(supabase_url) or '?'} is not local")
    elif target == "prod":
        if not _db_names_ref(db_url, PROD_REF):
            problems.append(f"LEDGER_DB_URL does not point at project {PROD_REF}")
        if supabase_url and _host(supabase_url) != f"{PROD_REF}.supabase.co":
            problems.append(f"SUPABASE_URL is not https://{PROD_REF}.supabase.co")
    else:
        problems.append(f"unknown target {target!r}")
    return problems


def confirm_prod_write(confirmation: str | None, *, interactive: bool, prompt=input) -> bool:
    """A prod --apply needs the project ref, from --yes-i-mean-prod or typed at the prompt."""
    if confirmation is not None:
        return confirmation.strip() == PROD_REF
    if not interactive:
        return False
    typed = prompt(f"This WRITES to production project {PROD_REF}. Type the project ref to continue: ")
    return typed.strip() == PROD_REF


def guard_target(args: argparse.Namespace) -> None:
    db_url = env("LEDGER_DB_URL")
    supabase_url = os.environ.get("SUPABASE_URL", "").strip() or None
    problems = check_target(args.target, db_url, supabase_url)
    if problems:
        sys.exit(f"refusing to run with --target {args.target}: " + "; ".join(problems))
    if args.target == "prod" and args.apply:
        if not confirm_prod_write(args.yes_i_mean_prod, interactive=sys.stdin.isatty()):
            sys.exit(f"refusing to write to production: pass --yes-i-mean-prod {PROD_REF} or type it at the prompt")
    print(f"target: {args.target} ({'APPLY' if args.apply else 'dry-run'})")


def connect() -> psycopg.Connection:
    return psycopg.connect(env("LEDGER_DB_URL"), autocommit=False)


def decrypt(value: str, fernet) -> str:
    if not value.startswith(ENC_PREFIX):
        return value
    return fernet.decrypt(value[len(ENC_PREFIX):].encode()).decode()


# ── 1. metadata ─────────────────────────────────────────────────────────────
def step_metadata(conn: psycopg.Connection, members: dict[str, str], apply: bool) -> None:
    with conn.cursor() as cur:
        cur.execute("select key from legacy.profiles order by id")
        keys = [r[0] for r in cur.fetchall()]
        print(f"legacy profiles: {keys}")
        missing = [k for k in keys if k not in members]
        if missing:
            print(f"WARNING: no member email given for {missing}; they will have no owner until invited")
        cur.execute("select private.import_legacy_metadata(%s::jsonb)", (json.dumps(members),))
        result = cur.fetchone()[0]
        print(json.dumps(result, indent=2))
    conn.commit() if apply else conn.rollback()
    print("metadata:", "APPLIED" if apply else "dry-run (rolled back)")


# ── 2. secrets ──────────────────────────────────────────────────────────────
def step_secrets(conn: psycopg.Connection, apply: bool, functions_env_out: str | None) -> None:
    from cryptography.fernet import Fernet

    fernet = Fernet(env("LEGACY_FERNET_KEY").encode())
    counts = {"pdf_passwords": 0, "mailbox_tokens": 0, "app_secrets": 0, "skipped": 0}
    app_secrets: dict[str, str] = {}
    with conn.cursor() as cur:
        cur.execute(
            """select p.key, s.key, s.value
               from legacy.runtime_settings s join legacy.profiles p on p.id = s.profile_id
               where coalesce(s.value, '') <> ''"""
        )
        rows = cur.fetchall()
        for profile_key, key, raw in rows:
            value = decrypt(raw, fernet)
            cur.execute("select profile_code from public.profiles where key = %s", (profile_key,))
            row = cur.fetchone()
            if row is None:
                counts["skipped"] += 1
                continue
            profile_code = row[0]
            if PDF_SECRET_KEY.match(key):
                cur.execute("select private.vault_upsert(%s, %s)", (f"profile:{profile_code}:{key}", value))
                counts["pdf_passwords"] += 1
            elif m := MAILBOX_SECRET_KEY.match(key):
                provider = "gmail" if m.group(1) == "GMAIL" else "outlook"
                cur.execute(
                    """select nm.mailbox_code
                       from legacy.email_mailboxes lm
                       join public.email_mailboxes nm on nm.profile_code = %s and nm.mailbox_email = lm.mailbox_email
                         and nm.provider = %s
                       where lm.id = %s""",
                    (profile_code, provider, int(m.group(2))),
                )
                mbx = cur.fetchone()
                if mbx is None:
                    counts["skipped"] += 1
                    continue
                cur.execute("select private.vault_upsert(%s, %s)", (f"mailbox:{mbx[0]}:refresh_token", value))
                counts["mailbox_tokens"] += 1
            elif key in APP_SECRET_KEYS:
                name = APP_SECRET_KEYS[key]
                if name in app_secrets and app_secrets[name] != value:
                    # Values are never printed; the last profile's value wins.
                    print(f"WARNING: {name} differs between legacy profiles; using the value from {profile_key!r}")
                app_secrets[name] = value
                counts["app_secrets"] += 1
            else:
                counts["skipped"] += 1
    conn.commit() if apply else conn.rollback()
    print(json.dumps(counts), "APPLIED" if apply else "dry-run (rolled back)")
    if app_secrets:
        if functions_env_out and apply:
            path = Path(functions_env_out)
            existing = path.read_text() if path.exists() else ""
            lines = [ln for ln in existing.splitlines() if ln.split("=", 1)[0] not in app_secrets]
            lines += [f"{k}={v}" for k, v in sorted(app_secrets.items())]
            path.write_text("\n".join(lines) + "\n")
            path.chmod(0o600)
            print(f"wrote OAuth app credentials ({sorted(app_secrets)}) to {path}; "
                  f"then: supabase secrets set --env-file {path}")
        else:
            print(f"OAuth app credentials found for {sorted(app_secrets)}; pass --functions-env-out to export them")


# ── 3. pdfs ─────────────────────────────────────────────────────────────────
def legacy_reader():
    kind = os.environ.get("LEGACY_STORAGE", "gcs").strip() or "gcs"
    if kind == "local":
        root = Path(env("LEGACY_LOCAL_ROOT"))
        return lambda key: (root / key).read_bytes()
    from google.cloud import storage  # type: ignore[import-not-found]

    bucket = storage.Client().bucket(env("LEGACY_GCS_BUCKET"))
    return lambda key: bucket.blob(key).download_as_bytes()


def legacy_bank_hint(bank_codes: list[str | None]) -> str | None:
    """The legacy bank for a PDF when all its statements agree on a supported bank (SRV-09)."""
    codes = {(c or "").strip().upper() for c in bank_codes if c}
    if len(codes) != 1:
        return None
    code = codes.pop()
    return code if code in SUPPORTED_BANKS else None


def step_pdfs(conn: psycopg.Connection, apply: bool, limit: int | None) -> None:
    read = legacy_reader()
    base = env("SUPABASE_URL").rstrip("/")
    key = env("SUPABASE_SERVICE_ROLE_KEY")
    http = httpx.Client(timeout=60, headers={"Authorization": f"Bearer {key}", "apikey": key})
    counts = {"candidates": 0, "already_present": 0, "uploaded": 0, "missing_in_storage": 0, "with_bank_hint": 0,
              "orphans_removed": 0}
    profile_codes: dict[str, str] = {}
    with conn.cursor() as cur:
        # Real statements first (oldest first), SIB history extracts last.
        cur.execute(
            """select f.id, p.key, f.storage_key, coalesce(f.original_filename, 'legacy.pdf'),
                      min(s.statement_date) as first_date,
                      bool_or(coalesce(s.statement_reference, '') like 'AUTO-SIB-%%') as is_history,
                      array_remove(array_agg(distinct s.bank_code), null) as bank_codes
               from legacy.pdf_files f
               join legacy.profiles p on p.id = f.profile_id
               left join legacy.statements s on s.pdf_file_id = f.id
               group by f.id, p.key, f.storage_key, f.original_filename
               order by is_history nulls last, first_date nulls last, f.id"""
        )
        rows = cur.fetchall()
        if limit:
            rows = rows[:limit]
        for profile_key in sorted({r[1] for r in rows}):
            cur.execute("select profile_code from public.profiles where key = %s", (profile_key,))
            row = cur.fetchone()
            if row is None:
                sys.exit(f"profile {profile_key!r} is not in public.profiles; run --step metadata --apply first")
            profile_codes[profile_key] = row[0]
        seen: set[tuple[str, str]] = set()
        for _fid, profile_key, storage_key, filename, _first, _hist, bank_codes in rows:
            counts["candidates"] += 1
            try:
                data = read(storage_key)
            except Exception:  # noqa: BLE001 — a missing object is reported, not fatal
                counts["missing_in_storage"] += 1
                continue
            digest = hashlib.sha256(data).hexdigest()
            profile_code = profile_codes[profile_key]
            if (profile_code, digest) in seen:
                counts["already_present"] += 1
                continue
            seen.add((profile_code, digest))
            cur.execute("select 1 from public.documents where profile_code = %s and sha256 = %s", (profile_code, digest))
            if cur.fetchone():
                counts["already_present"] += 1
                continue
            # Legacy parsed this PDF as a known bank: pass it as the hint, as legacy scraper
            # uploads were, instead of relying on content detection (SRV-08/09).
            bank_code = legacy_bank_hint(list(bank_codes or []))
            if bank_code:
                counts["with_bank_hint"] += 1
            if not apply:
                counts["uploaded"] += 1
                continue
            cur.execute("select public.gen_code('doc')")
            doc_code = cur.fetchone()[0]
            path = f"{profile_code}/{doc_code}.pdf"
            object_url = f"{base}/storage/v1/object/statements/{path}"
            # Upload first: the INSERT trigger enqueues the parse, so the object must exist.
            resp = http.post(object_url, content=data, headers={"Content-Type": "application/pdf", "x-upsert": "true"})
            resp.raise_for_status()
            try:
                cur.execute(
                    """insert into public.documents (doc_code, profile_code, storage_path, original_filename, sha256,
                         size_bytes, source, bank_code)
                       values (%s, %s, %s, %s, %s, %s, 'legacy', %s)
                       on conflict (profile_code, sha256) do nothing
                       returning doc_code""",
                    (doc_code, profile_code, path, filename, digest, len(data), bank_code),
                )
                inserted = cur.fetchone() is not None
                conn.commit()
            except Exception:
                conn.rollback()
                _remove_object(http, base, path, counts)
                raise
            if not inserted:
                # Another run stored the same PDF meanwhile: don't leave our copy behind.
                _remove_object(http, base, path, counts)
                counts["already_present"] += 1
                continue
            counts["uploaded"] += 1
    conn.rollback()
    print(json.dumps(counts), "APPLIED" if apply else "dry-run")


def _remove_object(http: httpx.Client, base: str, path: str, counts: dict[str, int]) -> None:
    try:
        http.request("DELETE", f"{base}/storage/v1/object/statements", json={"prefixes": [path]}).raise_for_status()
        counts["orphans_removed"] += 1
    except httpx.HTTPError as exc:
        print(f"WARNING: could not remove orphan storage object {path}: {type(exc).__name__}")


# ── 4. finalize ─────────────────────────────────────────────────────────────
def step_finalize(conn: psycopg.Connection, apply: bool) -> None:
    with conn.cursor() as cur:
        cur.execute("select parse_status, count(*) from public.documents group by 1 order by 1")
        print("documents:", dict(cur.fetchall()))
        cur.execute("select private.apply_legacy_category_choices()")
        print("legacy category choices applied:", cur.fetchone()[0])
        cur.execute(
            """select profile_key, bank_code, count(*) as months,
                      sum(legacy_lines), sum(v2_lines), sum(legacy_aed), sum(v2_aed),
                      count(*) filter (where abs(delta_aed) > 0.01),
                      sum(legacy_lines_missing), sum(legacy_aed_missing)
               from private.legacy_parity_report() group by 1, 2 order by 1, 2"""
        )
        print("parity (profile, bank, months, legacy_lines, v2_lines, legacy_aed, v2_aed, months_with_delta,"
              " legacy_lines_missing, legacy_aed_missing):")
        for row in cur.fetchall():
            print("  ", row)
    conn.commit() if apply else conn.rollback()
    print("finalize:", "APPLIED" if apply else "dry-run (rolled back)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", required=True, choices=["local", "prod"],
                    help="which Supabase project the environment must point at (checked)")
    ap.add_argument("--yes-i-mean-prod", default=None, metavar="REF",
                    help="confirm --apply against prod by repeating the project ref")
    ap.add_argument("--step", required=True, choices=["metadata", "secrets", "pdfs", "finalize"])
    ap.add_argument("--apply", action="store_true", help="write changes (default is a dry run)")
    ap.add_argument("--members", default="{}", help='JSON {"<legacy profile key>": "<owner email>"}')
    ap.add_argument("--functions-env-out", default=None)
    ap.add_argument("--limit", type=int, default=None)
    args = ap.parse_args()
    guard_target(args)

    with connect() as conn:
        if args.step == "metadata":
            step_metadata(conn, json.loads(args.members), args.apply)
        elif args.step == "secrets":
            step_secrets(conn, args.apply, args.functions_env_out)
        elif args.step == "pdfs":
            step_pdfs(conn, args.apply, args.limit)
        else:
            step_finalize(conn, args.apply)


if __name__ == "__main__":
    main()
