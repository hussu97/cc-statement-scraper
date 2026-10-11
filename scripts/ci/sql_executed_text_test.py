#!/usr/bin/env python3
"""Tests for sql_executed_text.py and check-migrations.sh's destructive guard.

Run: python3 scripts/ci/sql_executed_text_test.py   (CI: tooling job; pre-push: tooling)
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

from sql_executed_text import executed_text  # noqa: E402

DESTRUCTIVE = re.compile(r"\b(drop\s+(table|schema|column)|truncate|delete\s+from)\b", re.IGNORECASE)


def hits(sql: str) -> list[int]:
    """1-based line numbers of destructive statements that run."""
    return [n for n, line in enumerate(executed_text(sql).splitlines(), 1) if DESTRUCTIVE.search(line)]


class ExecutedText(unittest.TestCase):
    def test_top_level_delete_is_flagged(self):
        self.assertEqual(hits("select 1;\ndelete from public.t where x;\n"), [2])

    def test_top_level_drop_and_truncate_are_flagged(self):
        self.assertEqual(hits("drop table _tmp;\ntruncate public.t;\nalter table t drop column c;\n"), [1, 2, 3])

    def test_delete_inside_a_function_body_is_not_flagged(self):
        sql = (
            "create or replace function private.f()\nreturns void\nlanguage plpgsql\nas $$\n"
            "begin\n  delete from public.t;\n  truncate _tmp;\nend;\n$$;\n"
        )
        self.assertEqual(hits(sql), [])

    def test_named_tags_upper_case_and_procedures(self):
        sql = (
            "CREATE OR REPLACE FUNCTION private.g()\n RETURNS void\nAS $function$\n  delete from t;\n$function$;\n"
            "create procedure p() language sql as $body$ delete from t $body$;\n"
            "create function h() returns int language sql as $$ select 1 $$;\n"
        )
        self.assertEqual(hits(sql), [])

    def test_do_block_is_flagged(self):
        sql = "do $$\nbegin\n  delete from public.t;\nend\n$$;\n"
        self.assertEqual(hits(sql), [3])

    def test_cron_command_is_flagged(self):
        sql = "select cron.schedule('purge', '0 0 * * *',\n  $$delete from public.t$$);\n"
        self.assertEqual(hits(sql), [2])

    def test_comments_are_not_flagged(self):
        sql = "-- delete from t\n/* truncate t; /* nested drop table x */ still comment */\nselect 1; -- drop table y\n"
        self.assertEqual(hits(sql), [])

    def test_comment_inside_a_do_block_is_not_flagged(self):
        self.assertEqual(hits("do $$\nbegin\n  -- delete from t\n  perform 1;\nend $$;\n"), [])

    def test_string_executed_in_a_do_block_is_flagged(self):
        self.assertEqual(hits("do $$ begin execute 'delete from t'; end $$;\n"), [1])

    def test_a_statement_after_a_function_is_flagged(self):
        sql = "create function f() returns void language sql as $$ delete from a $$;\ndelete from b;\n"
        self.assertEqual(hits(sql), [2])

    def test_function_after_a_do_block_is_classified_by_its_own_statement(self):
        sql = "do $$ begin perform 1; end $$;\ncreate function f() returns void language sql as $$\ndelete from a\n$$;\n"
        self.assertEqual(hits(sql), [])

    def test_quotes_and_dollar_signs_in_strings_do_not_open_a_body(self):
        sql = "comment on table t is 'costs $$ and it''s fine';\ndelete from t;\nselect E'a\\'b $$';\ndelete from u;\n"
        self.assertEqual(hits(sql), [2, 4])

    def test_positional_parameters_are_not_dollar_tags(self):
        sql = "create function f(int) returns int language sql as $$ select $1 $$;\ndelete from t;\n"
        self.assertEqual(hits(sql), [2])

    def test_line_numbers_and_length_are_preserved(self):
        sql = "-- a\ncreate function f() returns void language sql as $$\n delete from t;\n$$;\nselect 1;\n"
        out = executed_text(sql)
        self.assertEqual(len(out), len(sql))
        self.assertEqual(out.count("\n"), sql.count("\n"))
        self.assertIn("select 1;", out.splitlines()[4])


class Guard(unittest.TestCase):
    """check-migrations.sh destructive <file>: the guard the deploy runs."""

    def run_guard(self, *files: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", os.path.join(ROOT, "scripts/ci/check-migrations.sh"), "destructive", *files],
            cwd=ROOT, capture_output=True, text=True,
        )

    def test_redefining_functions_that_delete_passes(self):
        # Blocked the 2026-10-11 deploy: refresh_transaction / match_sms bodies delete when called.
        r = self.run_guard("supabase/migrations/20261011000100_bank_fx_fees.sql")
        self.assertEqual((r.returncode, r.stdout), (0, ""), r.stderr)

    def test_a_real_top_level_drop_is_still_caught(self):
        r = self.run_guard("supabase/migrations/20261009000200_db_categorisation_and_jobs.sql")
        self.assertEqual(r.returncode, 1)
        self.assertIn(":38:drop table _seed_fix;", r.stdout)

    def test_synthetic_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
            f.write("create function f() returns void language sql as $$ delete from a $$;\n-- truncate b\ndo $$ begin delete from c; end $$;\n")
        try:
            r = self.run_guard(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(r.returncode, 1)
        self.assertEqual([line.split(":")[1] for line in r.stdout.splitlines()], ["3"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
