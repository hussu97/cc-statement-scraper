#!/usr/bin/env python3
"""PreToolUse guard for Claude Code (wired in .claude/settings.json).

Turns the CLAUDE.md rules that a Bash command or file read can break into
enforced ones, so they don't depend on being remembered:

  deny  `git add -A` / `.` / `-u`, `git commit -a`      (CLAUDE.md §9: stage explicit paths)
  deny  `git commit` without the exact --author, or with a Co-Authored-By trailer (§9)
  deny  printing a secret file, env dump or token       (§11.4: never print secrets)
  deny  dropping the `legacy` schema, `rm -r` of backend/ or data/, `db reset --linked` (§11.3)
  ask   every production action: push to main, db push, functions deploy, secrets,
        Vault, Cloud Run, Vercel, gh secrets/workflows, TestFlight, prod SQL (§11.1-11.2)
  ask   bypassing git hooks (--no-verify, SKIP_PRE_PUSH)

"ask" still shows the normal permission prompt, so the user confirms in the
moment. Reads JSON from stdin; prints a PreToolUse decision or nothing (allow).
Tests: python3 .claude/hooks/guard_test.py
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys

PROD_REF = "nkmylznisjcnmqbxosey"

# A secret file: any .env / .env.* except .env.example, any Secrets*.xcconfig except the
# example, Apple keys and provisioning profiles.
SECRET_PATH = re.compile(
    r"(^|/)(\.env(\.[\w.-]+)?|Secrets[\w.-]*\.xcconfig|[\w.-]+\.(p8|p12|mobileprovision))$"
)
SECRET_EXAMPLE = re.compile(r"(^|/)(\.env\.example|Secrets\.example\.xcconfig)$")

READERS = {
    "cat", "less", "more", "head", "tail", "bat", "nl", "xxd", "od", "hexdump", "strings",
    "sed", "awk", "grep", "egrep", "rg", "cut", "sort", "uniq", "diff", "base64", "openssl",
    "jq", "python", "python3", "node", "column", "tee", "pbcopy",
}

# (pattern, reason) — production actions that need a fresh "yes" in chat.
ASK_PROD = [
    (r"\bsupabase\s+db\s+push\b(?![^;&|]*--dry-run)", "supabase db push applies migrations to a remote database"),
    (r"\bsupabase\s+functions\s+(deploy|delete)\b", "deploys/deletes Edge Functions"),
    (r"\bsupabase\s+secrets\s+(set|unset)\b", "changes Edge Function secrets"),
    (r"\bsupabase\s+(config\s+push|migration\s+repair|storage\s+(rm|mv|cp))\b", "changes the remote Supabase project"),
    (r"scripts/cutover/", "production secret/Vault helper"),
    (r"\bvault_upsert\b|\bvault\.(create|update)_secret\b", "writes a Vault secret"),
    (r"pooler\.supabase\.com|db\." + PROD_REF + r"|\$\{?LEDGER_DB_URL\b", "SQL against the production database"),
    (r"\bgcloud\s+run\s+(deploy|services\s+(update|update-traffic|delete|replace))\b", "changes the Cloud Run parser"),
    (r"\bgcloud\s+(secrets\s+(create|delete|versions\s+(add|destroy|disable))|builds\s+submit)\b", "changes GCP secrets/builds"),
    (r"\bgcloud\s+(iam|projects\s+(add|remove)-iam-policy-binding)\b", "changes GCP IAM"),
    (r"\bvercel\b[^;&|]*(--prod\b|\b(deploy|promote|rollback|redeploy)\b|\benv\s+(add|rm|remove|pull)\b)", "Vercel production deploy/env"),
    (r"\bgh\s+(secret|variable)\s+(set|delete|remove)\b", "changes GitHub Actions secrets/variables"),
    (r"\bgh\s+workflow\s+(run|enable|disable)\b", "dispatches/toggles a GitHub workflow"),
    (r"\bgh\s+(release\s+(create|delete|upload|edit)|pr\s+merge)\b", "publishes a release or merges a PR"),
    (r"\bgh\s+api\b[^;&|]*(-X|--method)\s*(PUT|POST|PATCH|DELETE)\b", "writes through the GitHub API"),
    (r"apps/ios/scripts/(testflight|publish-build)\.sh|testflight-distribute", "builds/uploads a TestFlight release"),
]

# `--linked` / the prod ref with a subcommand that only reads is fine.
LINKED_READONLY = re.compile(
    r"\bsupabase\s+(migration\s+(list|fetch)|db\s+(dump|diff|lint|push\s+[^;&|]*--dry-run)|inspect\b|"
    r"link\b|projects\s+list|functions\s+list|secrets\s+list|gen\s+types)"
)

I = re.I
DENY = [
    (re.compile(r"\bdrop\s+schema\s+(if\s+exists\s+)?\"?legacy\"?\b", I),
     "the `legacy` schema is the historical record of v1 and is never dropped"),
    (re.compile(r"\bdrop\s+table\s+(if\s+exists\s+)?\"?legacy\"?\.", I), "legacy tables are never dropped"),
    (re.compile(r"\b(truncate|delete\s+from|update)\s+(table\s+)?\"?legacy\"?\.", I), "the `legacy` schema is read-only"),
    (re.compile(r"\bsupabase\s+db\s+reset\b[^;&|]*(--linked|--db-url)"), "db reset against a remote database wipes it"),
    (re.compile(r"\bprintenv\b|(^|[;&|]\s*)env\s*($|[|;&>])|\bset\s*\|"), "dumps the environment, which holds secrets"),
    (re.compile(r"(?<!\$\()\bgh\s+auth\s+token\b(?![^;&|)]*\))"),
     "prints a GitHub token; use GH_TOKEN=$(gh auth token --user hussu97) inline"),
    (re.compile(r"\b(echo|printf)\b[^;&|]*\$\{?[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|_KEY|_KEYS|DSN)\b"),
     "prints a secret variable"),
]

# rm -r of the folders that hold the only local copies of private PDFs, backups and logs.
PROTECTED_DIR = re.compile(r"^(\./)?(backend|data)(/.*)?$|/credit-card-scraper/(backend|data)(/.*)?$")


def git_branch(cwd: str) -> str:
    try:
        out = subprocess.run(["git", "-C", cwd or ".", "branch", "--show-current"],
                             capture_output=True, text=True, timeout=3)
        return out.stdout.strip()
    except Exception:
        return ""


def segments(command: str) -> list[str]:
    """Split on ; && || | and newlines (quote-unaware, which errs towards checking more)."""
    return [s.strip() for s in re.split(r"\|\||&&|[;|\n]", command) if s.strip()]


def words(segment: str) -> list[str]:
    try:
        return shlex.split(segment, comments=False, posix=True)
    except ValueError:
        return segment.split()


def git_sub(ws: list[str]) -> tuple[str, list[str]]:
    """('add', args) for `git [-C dir] [-c k=v] add args`; ('', []) when not git."""
    i = 0
    while i < len(ws) and re.match(r"^[A-Z_][A-Z0-9_]*=", ws[i]):  # VAR=value prefixes
        i += 1
    if i >= len(ws) or os.path.basename(ws[i]) != "git":
        return "", []
    i += 1
    while i < len(ws) and ws[i].startswith("-"):
        i += 2 if ws[i] in ("-C", "-c", "--git-dir", "--work-tree") else 1
    return (ws[i], ws[i + 1:]) if i < len(ws) else ("", [])


AUTHOR = re.compile(r"--author[= ]\s*([\"'])Hussain Abbasi <h_abbasi97@hotmail\.com>\1")
MESSAGE_CMD = re.compile(r"\bgit\s+(\S+\s+)*?(commit|tag|merge|revert)\b|\bgh\s+(pr|issue|release)\s+(create|edit|comment)\b")


def strip_messages(command: str) -> str:
    """Drop commit/PR message text (heredoc bodies, -m/--body strings) so prose that mentions
    `supabase db push` or `git add -A` isn't mistaken for the command itself."""
    if not MESSAGE_CMD.search(command):
        return command
    out = re.sub(r"<<-?\s*(['\"]?)(\w+)\1.*?\n\s*\2\b", "<<MSG", command, flags=re.S)
    return re.sub(r"(\s(-m|--message|-b|--body|-t|--title|-F)\s*=?\s*)(\"(\\.|[^\"\\])*\"|'[^']*')", r"\1MSG", out, flags=re.S)


def check_git(seg: str, raw: str, cwd: str) -> tuple[str, str] | None:
    sub, args = git_sub(words(seg))
    if sub == "add":
        for a in args:
            if a in ("-A", "--all", "-u", "--update", ".", ":/", "*", "--no-ignore-removal") or \
               re.fullmatch(r"-[a-zA-Z]*[Au][a-zA-Z]*", a):
                return "deny", ("Stage explicit paths only (CLAUDE.md §9): `git add path/one path/two`. "
                                "`git add -A`/`.`/`-u` once swept another session's staged deletion "
                                "of backend/ into an iOS commit (f530ca1).")
    if sub == "commit":
        if any(a == "--all" or re.fullmatch(r"-[a-zA-Z]*a[a-zA-Z]*", a) for a in args):
            return "deny", "No `git commit -a` (CLAUDE.md §9): stage explicit paths, then commit."
        if re.search(r"(^|\n|[\"'])\s*co-authored-by:", raw, re.I):
            return "deny", "No Co-Authored-By trailer of any kind (CLAUDE.md §9)."
        if not AUTHOR.search(raw):
            return "deny", ('Every commit is authored exactly (CLAUDE.md §9): '
                            'git commit --author="Hussain Abbasi <h_abbasi97@hotmail.com>" -m "..."')
        if "--no-verify" in args or "-n" in args:
            return "ask", "Commit bypasses the pre-commit secrets/migration guards (--no-verify)."
    if sub == "push":
        if "--no-verify" in args or re.search(r"\bSKIP_PRE_PUSH=", seg):
            return "ask", "Push bypasses the pre-push CI mirror."
        if any(a in ("-f", "--force") or a.startswith("--force") or a.startswith("+") for a in args):
            return "ask", "Force push rewrites remote history."
        refs = [a for a in args if not a.startswith("-")]
        to_main = any(re.search(r"(^|:)(refs/heads/)?main$", r) for r in refs[1:]) or \
            (len(refs) <= 1 and git_branch(cwd) == "main") or "--all" in args or "--mirror" in args
        if to_main:
            return "ask", ("A push to main is a production deploy (CLAUDE.md §11.2): Supabase migrations + "
                           "functions, the Cloud Run parser, Vercel, and TestFlight when the iOS app changed.")
    return None


def is_secret(path: str) -> bool:
    p = path.strip("'\"")
    return bool(SECRET_PATH.search(p)) and not SECRET_EXAMPLE.search(p)


def check_secret_read(seg: str) -> tuple[str, str] | None:
    ws = words(seg)
    if not ws or not any(is_secret(w) for w in ws[1:]):
        return None
    cmd = os.path.basename(ws[0])
    if cmd in ("grep", "egrep", "rg") and any(re.fullmatch(r"-[a-zA-Z]*[cqlL][a-zA-Z]*", w) for w in ws[1:]):
        return None  # count / quiet / file names only
    if cmd == "cut" and re.search(r"-d\s*'?=?'?\S*\s.*-f\s*1\b|-f\s*1\b.*-d", seg):
        return None  # key names only
    if cmd in READERS:
        return "deny", ("Never print secret values (CLAUDE.md §11.4). Check shape, not value: "
                        "`cut -d= -f1 FILE` for key names, `grep -c '^KEY=' FILE` for presence.")
    return None


def decide_bash(raw: str, cwd: str) -> tuple[str, str] | None:
    command = strip_messages(raw)
    for pat, reason in DENY:
        if pat.search(command):
            return "deny", reason + " (CLAUDE.md §11)"
    for seg in segments(command):
        ws = words(seg)
        if ws and os.path.basename(ws[0]) == "rm" and \
           any(re.fullmatch(r"-[a-zA-Z]*[rR][a-zA-Z]*|--recursive", w) for w in ws[1:]) and \
           any(PROTECTED_DIR.search(w) for w in ws[1:] if not w.startswith("-")):
            return "deny", ("backend/ and data/ hold the only local copies of private statement PDFs, "
                            "backups and logs; they are never deleted (CLAUDE.md §11.3).")
        hit = check_git(seg, raw, cwd) or check_secret_read(seg)
        if hit:
            return hit
    for pat, reason in ASK_PROD:
        if re.search(pat, command, re.I):
            return "ask", f"Production action: {reason}. Needs an explicit yes in chat (CLAUDE.md §11.1)."
    if (re.search(r"--linked\b|--project-ref\b|" + PROD_REF, command)) and not LINKED_READONLY.search(command):
        return "ask", "Command targets the production Supabase project (CLAUDE.md §11.1)."
    return None


def decide(payload: dict) -> tuple[str, str] | None:
    tool = payload.get("tool_name", "")
    tin = payload.get("tool_input") or {}
    if tool == "Bash":
        return decide_bash(tin.get("command", ""), payload.get("cwd", ""))
    if tool == "Read" and is_secret(tin.get("file_path", "")):
        return "deny", ("Never read secret files into the transcript (CLAUDE.md §11.4). Check key names "
                        "with `cut -d= -f1 FILE` instead.")
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    hit = decide(payload)
    if hit:
        decision, reason = hit
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
