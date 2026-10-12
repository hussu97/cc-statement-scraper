#!/usr/bin/env python3
"""PreToolUse guard for Claude Code (wired in .claude/settings.json).

Turns the CLAUDE.md rules that a Bash command or file read can break into
enforced ones, so they don't depend on being remembered:

  deny  `git add -A` / `.` / `-u`, `git commit -a`      (CLAUDE.md §9: stage explicit paths)
  deny  `git commit` without the exact --author, or with a Co-Authored-By trailer (§9)
  deny  printing a secret file, env dump or token       (§11.4: never print secrets)
  deny  recursive grep -r / rg -uu / find -exec cat over a directory holding one, unless excluded
  deny  dropping the `legacy` schema, `rm -r` of backend/ or data/, `db reset --linked` (§11.3)
  ask   every production action: push to main, db push, functions deploy, secrets,
        Vault, Cloud Run, Vercel, gh secrets/workflows, TestFlight, prod SQL (§11.1-11.2)
  ask   bypassing git hooks (--no-verify, SKIP_PRE_PUSH)

"ask" still shows the normal permission prompt, so the user confirms in the
moment. Reads JSON from stdin; prints a PreToolUse decision or nothing (allow).
Tests: python3 .claude/hooks/guard_test.py
"""

from __future__ import annotations

import fnmatch
import glob
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


# Where the gitignored secret files of CLAUDE.md §11.4 live, relative to the repo root, with
# example names. A clean clone has none of them, so these are known statically; secrets_under()
# adds whatever is actually on disk under a search root.
SECRET_DIRS = {
    ".": [".env", ".env.cutover", ".env.production"],
    "supabase/functions": [".env", ".env.production"],
    "services/parser": [".env", ".env.production"],
    "apps/web": [".env.local", ".env.production.local"],
    "apps/ios/Config": ["Secrets.xcconfig", "Secrets.Release.xcconfig"],
    "scraper": [".env"],
}
PRUNE = {".git", "node_modules", ".venv", "venv", "dist", "build", ".build", "Pods", "DerivedData"}
GLOB = re.compile(r"[*?\[]")


def repo_top(cwd: str) -> str:
    try:
        out = subprocess.run(["git", "-C", cwd or ".", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=3)
        return out.stdout.strip() or cwd
    except Exception:
        return cwd


def secrets_under(roots: list[str], cwd: str, top: str) -> list[str]:
    """Names of secret files a recursive walk of `roots` (relative to cwd) would open."""
    found: set[str] = set()
    for root in roots:
        if GLOB.search(root):
            matches = glob.glob(os.path.join(cwd, root)) if os.path.isdir(cwd or "") else []
            if not matches:  # can't expand here: assume the directory part before the glob
                matches = [os.path.join(cwd, root[:GLOB.search(root).start()].rpartition("/")[0] or ".")]
            paths = matches
        else:
            paths = [os.path.join(cwd, root)]
        for path in (os.path.normpath(p) for p in paths):
            if is_secret(path):
                found.add(os.path.basename(path))
            for rel, names in SECRET_DIRS.items():
                d = os.path.normpath(os.path.join(top, rel))
                if d == path or d.startswith(path.rstrip("/") + "/"):
                    found.update(names)
            if os.path.isdir(path):
                for n, (dirpath, dirnames, filenames) in enumerate(os.walk(path)):
                    dirnames[:] = [x for x in dirnames if x not in PRUNE]
                    found.update(f for f in filenames if is_secret(os.path.join(dirpath, f)))
                    if n > 5000:
                        break
    return sorted(found)


def short_opts(w: str, with_value: str) -> tuple[str, bool]:
    """Flags of a short-option cluster like -rniE, and whether the next word is a flag's value."""
    flags = ""
    for i, ch in enumerate(w[1:]):
        flags += ch
        if ch in with_value:
            return flags, i == len(w) - 2
    return flags, False


def grep_like(ws: list[str], value_short: str, value_long: set[str]) -> tuple[list[str], list[str], list[str]]:
    """(flags, long options as 'name=value', positional args) of a grep/rg command line."""
    flags, longs, pos, i, explicit_pattern = [], [], [], 1, False
    while i < len(ws):
        w = ws[i]
        if w == "--":
            pos += ws[i + 1:]
            break
        if w.startswith("--"):
            name = w.split("=", 1)[0]
            if "=" not in w and name in value_long and i + 1 < len(ws):
                w, i = f"{w}={ws[i + 1]}", i + 1
            longs.append(w)
            explicit_pattern |= name in ("--regexp", "--file")
        elif w.startswith("-") and len(w) > 1:
            f, takes_next = short_opts(w, value_short)
            flags.append(f)
            explicit_pattern |= bool(set(f) & set("ef"))
            if takes_next and i + 1 < len(ws):
                if f[-1] == "g":
                    longs.append(f"--glob={ws[i + 1]}")
                i += 1
            elif f and f[-1] == "g" and len(w) > 2:
                longs.append("--glob=" + w[w.index("g") + 1:])
        else:
            pos.append(w)
        i += 1
    return list("".join(flags)), longs, pos[0 if explicit_pattern else 1:]


def long_values(longs: list[str], *names: str) -> list[str]:
    return [l.split("=", 1)[1].strip("'\"") for l in longs if "=" in l and l.split("=", 1)[0] in names]


def unexcluded(names: list[str], include: list[str], exclude: list[str]) -> list[str]:
    return [n for n in names if not any(fnmatch.fnmatch(n, p) for p in exclude)
            and (not include or any(fnmatch.fnmatch(n, p) for p in include))]


GREP_LONG = {"--regexp", "--file", "--include", "--exclude", "--exclude-dir", "--exclude-from",
             "--max-count", "--context", "--after-context", "--before-context", "--label",
             "--devices", "--directories", "--binary-files"}
RG_LONG = {"--regexp", "--file", "--glob", "--iglob", "--type", "--type-not", "--max-count",
           "--context", "--after-context", "--before-context", "--max-depth", "--replace",
           "--threads", "--max-filesize", "--type-add", "--encoding", "--sort", "--sortr"}
NAMES_ONLY = {"--files-with-matches", "--files-without-match", "--count", "--count-matches",
              "--quiet", "--silent", "--files"}


def recursive_secrets(pipeline: list[str], cwd: str, top: str) -> list[str]:
    """Secret files a recursive grep / rg / find in this pipeline would print, after its excludes."""
    for k, stage in enumerate(pipeline):
        ws = words(stage)
        while ws and re.match(r"^[A-Z_][A-Z0-9_]*=", ws[0]):
            ws = ws[1:]
        cmd = os.path.basename(ws[0]) if ws else ""
        if cmd in ("grep", "egrep", "fgrep"):
            flags, longs, roots = grep_like(ws, "ABCDdefm", GREP_LONG)
            recursive = bool(set(flags) & {"r", "R"}) or \
                any(l in ("--recursive", "--dereference-recursive", "--directories=recurse") for l in longs)
            if not recursive or set(flags) & set("lLcq") or set(longs) & NAMES_ONLY:
                continue
            names = secrets_under(roots or ["."], cwd, top)
            return unexcluded(names, long_values(longs, "--include"), long_values(longs, "--exclude"))
        if cmd == "rg":
            flags, longs, roots = grep_like(ws, "ABCdEefgjMmrTt", RG_LONG)
            u = flags.count("u")
            no_ignore = u >= 1 or any(l in ("--no-ignore", "--no-ignore-vcs") for l in longs)
            hidden = u >= 2 or "." in flags or "--hidden" in longs
            if not (no_ignore and hidden) or set(flags) & set("lcq") or set(longs) & NAMES_ONLY:
                continue
            globs = long_values(longs, "--glob", "--iglob")
            names = secrets_under(roots or ["."], cwd, top)
            return unexcluded(names, [g for g in globs if not g.startswith("!")],
                              [g[1:] for g in globs if g.startswith("!")])
        if cmd == "find":
            i = 1
            while i < len(ws) and ws[i] in ("-H", "-L", "-P", "-D", "-O"):
                i += 2 if ws[i] in ("-D", "-O") else 1
            roots = []
            while i < len(ws) and not ws[i].startswith("-") and ws[i] not in ("(", "!", ")"):
                roots.append(ws[i])
                i += 1
            execs = [ws[j + 1] for j in range(i, len(ws) - 1) if ws[j] in ("-exec", "-execdir", "-ok", "-okdir")]
            if k + 1 < len(pipeline):  # find … | xargs cat
                xs = [w for w in words(pipeline[k + 1]) if not w.startswith("-")]
                if xs and os.path.basename(xs[0]) == "xargs":
                    execs += xs[1:]
            if not any(os.path.basename(e) in READERS for e in execs):
                continue
            include, exclude = [], []
            for j in range(i, len(ws) - 1):
                if ws[j] in ("-name", "-iname"):
                    (exclude if j > 0 and ws[j - 1] in ("!", "-not") else include).append(ws[j + 1])
            return unexcluded(secrets_under(roots or ["."], cwd, top), include, exclude)
    return []


def pipelines(command: str) -> list[list[str]]:
    """Split on ; && || and newlines into pipelines of | stages, keeping quoted text whole so a
    pattern like "a|b" stays one argument, and dropping heredoc bodies (they are data)."""
    command = re.sub(r"<<-?\s*(['\"]?)(\w+)\1.*?\n\s*\2\b", "<<DOC", command, flags=re.S)
    chains, stages, cur, quote, i = [], [], "", "", 0
    while i < len(command):
        c, two = command[i], command[i:i + 2]
        if quote:
            quote = "" if c == quote else quote
        elif c in "'\"":
            quote = c
        elif two in ("&&", "||") or c in ";\n|":
            stages.append(cur)
            cur = ""
            if c != "|" or two == "||":
                chains.append(stages)
                stages = []
            i += 2 if two in ("&&", "||") else 1
            continue
        cur += c
        i += 1
    chains.append(stages + [cur])
    return [[s.strip() for s in st if s.strip()] for st in chains]


def check_recursive_search(command: str, cwd: str) -> tuple[str, str] | None:
    start, top = cwd, None
    for stages in pipelines(command):
        chain = " | ".join(stages)
        ws = words(stages[0]) if stages else []
        if len(ws) == 2 and ws[0] == "cd":  # `cd dir && grep -r …` searches from dir
            cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(ws[1])))
            continue
        if top is None and re.search(r"\b(grep|egrep|fgrep|rg|find)\b", chain):
            top = os.path.normpath(repo_top(start) or "/")
        names = recursive_secrets(stages, cwd, top) if top else []
        if names:
            return "deny", (f"This recursive search covers gitignored secret files ({', '.join(names)}) and "
                            "would print their values (CLAUDE.md §11.4). Use `rg PATTERN DIR` (skips "
                            "gitignored files), or exclude them: `grep -rn PATTERN DIR --exclude='.env*' "
                            "--exclude='Secrets*.xcconfig'`, `find DIR -not -name '.env*' …`.")
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
    hit = check_recursive_search(command, cwd)
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
