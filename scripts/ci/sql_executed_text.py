#!/usr/bin/env python3
"""Print a SQL file with everything that does not run at migration time blanked out.

Used by check-migrations.sh's destructive guard, so `delete from` inside a function body
that a migration merely (re)defines no longer stops a deploy. Blanked (replaced by spaces,
newlines kept so grep line numbers still match the file):

  * `--` and `/* */` comments (nested, as Postgres allows);
  * the dollar-quoted body of `create [or replace] function|procedure`.

Everything else is kept, including `do $$ … $$` blocks, `cron.schedule(…, $$ … $$)` commands
and string literals (`execute 'delete from …'` runs), so the guard stays conservative.

Usage: sql_executed_text.py FILE   (tests: sql_executed_text_test.py)
"""

from __future__ import annotations

import re
import sys

_DOLLAR_TAG = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")
_ROUTINE = re.compile(r"^\s*create\s+(?:or\s+replace\s+)?(?:function|procedure)\b", re.IGNORECASE)


def _blank(text: str) -> str:
    return "".join(c if c == "\n" else " " for c in text)


def _strip_comments(text: str) -> str:
    """Blank comments only (inside a kept dollar body: its strings and nested quotes still run)."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(_blank(text[i:j]))
            i = j
        elif text.startswith("/*", i):
            j = _block_comment_end(text, i)
            out.append(_blank(text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def _block_comment_end(text: str, i: int) -> int:
    depth, j, n = 0, i, len(text)
    while j < n:
        if text.startswith("/*", j):
            depth += 1
            j += 2
        elif text.startswith("*/", j):
            depth -= 1
            j += 2
            if depth == 0:
                return j
        else:
            j += 1
    return n


def _quoted_end(text: str, i: int, quote: str, backslash: bool) -> int:
    """Index just past the literal or identifier that opens at text[i] == quote."""
    j, n = i + 1, len(text)
    while j < n:
        c = text[j]
        if backslash and c == "\\":
            j += 2
            continue
        if c == quote:
            if j + 1 < n and text[j + 1] == quote:  # doubled quote
                j += 2
                continue
            return j + 1
        j += 1
    return n


def executed_text(sql: str) -> str:
    out: list[str] = []
    statement: list[str] = []  # top-level text of the current statement, comments blanked
    i, n = 0, len(sql)
    while i < n:
        c = sql[i]
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            piece = _blank(sql[i:j])
        elif sql.startswith("/*", i):
            j = _block_comment_end(sql, i)
            piece = _blank(sql[i:j])
        elif c in "'\"":
            escaped = c == "'" and i > 0 and sql[i - 1] in "eE" and (i < 2 or not (sql[i - 2].isalnum() or sql[i - 2] == "_"))
            j = _quoted_end(sql, i, c, escaped)
            piece = sql[i:j]
        elif c == "$" and (m := _DOLLAR_TAG.match(sql, i)) and not (i > 0 and (sql[i - 1].isalnum() or sql[i - 1] == "_")):
            tag = m.group(0)
            close = sql.find(tag, m.end())
            j = n if close < 0 else close + len(tag)
            body = sql[m.end():close if close >= 0 else n]
            routine = bool(_ROUTINE.match("".join(statement)))
            kept = _blank(body) if routine else _strip_comments(body)
            piece = tag + kept + (tag if close >= 0 else "")
        else:
            j = i + 1
            piece = c
        out.append(piece)
        if piece == ";":
            statement = []
        else:
            statement.append(piece)
        i = j
    return "".join(out)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: sql_executed_text.py FILE", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        sys.stdout.write(executed_text(f.read()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
