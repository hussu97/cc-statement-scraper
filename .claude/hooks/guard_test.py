#!/usr/bin/env python3
"""Tests for guard.py. Run: python3 .claude/hooks/guard_test.py"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import guard  # noqa: E402

AUTHOR = '--author="Hussain Abbasi <h_abbasi97@hotmail.com>"'


def bash(cmd, cwd="/nonexistent"):
    hit = guard.decide({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd})
    return hit[0] if hit else "allow"


def read(path):
    hit = guard.decide({"tool_name": "Read", "tool_input": {"file_path": path}})
    return hit[0] if hit else "allow"


class Git(unittest.TestCase):
    def test_explicit_staging(self):
        for cmd in ["git add -A", "git add .", "git add --all", "git add -u", "git -C /x add -A",
                    "git add -Av", "cd x && git add . && git commit " + AUTHOR + ' -m "x"']:
            self.assertEqual(bash(cmd), "deny", cmd)
        for cmd in ["git add CLAUDE.md tasks/lessons.md", "git add -p CLAUDE.md", "git add ./apps/web/src/x.ts"]:
            self.assertEqual(bash(cmd), "allow", cmd)

    def test_commit(self):
        self.assertEqual(bash("git commit " + AUTHOR + ' -m "Docs: rules"'), "allow")
        self.assertEqual(bash("git commit --author='Hussain Abbasi <h_abbasi97@hotmail.com>' -m x"), "allow")
        self.assertEqual(bash('git commit -m "x"'), "deny")
        self.assertEqual(bash('git commit --author="Someone <a@b.c>" -m "x"'), "deny")
        self.assertEqual(bash("git commit -a " + AUTHOR + ' -m "x"'), "deny")
        self.assertEqual(bash("git commit -am x " + AUTHOR), "deny")
        self.assertEqual(bash("git commit " + AUTHOR + ' -m "x" -m "Co-Authored-By: Bot <b@x>"'), "deny")
        self.assertEqual(bash("git commit " + AUTHOR + ' --no-verify -m "x"'), "ask")

    def test_commit_message_prose_is_not_a_command(self):
        heredoc = ("git commit " + AUTHOR + " -m \"$(cat <<'EOF'\nRules: never git add -A; "
                   "supabase db push needs a yes; printenv is denied\n\nBody | with ; separators\nEOF\n)\"")
        self.assertEqual(bash(heredoc), "allow")
        self.assertEqual(bash("git commit " + AUTHOR + ' -m "Explain why there is no Co-Authored-By trailer"'), "allow")

    def test_push(self):
        self.assertEqual(bash("git push origin main"), "ask")
        self.assertEqual(bash("git push origin HEAD:main"), "ask")
        self.assertEqual(bash("git push origin feature:refs/heads/main"), "ask")
        self.assertEqual(bash("git push -u origin ledger-v3"), "allow")
        self.assertEqual(bash("git push --force origin ledger-v3"), "ask")
        self.assertEqual(bash("git push --no-verify origin ledger-v3"), "ask")
        self.assertEqual(bash("SKIP_PRE_PUSH=1 git push origin ledger-v3"), "ask")


class Production(unittest.TestCase):
    def test_asks(self):
        for cmd in ["supabase db push", "supabase functions deploy worker --use-api",
                    "supabase secrets set --env-file supabase/functions/.env.production",
                    "bash scripts/cutover/set-edge-secrets.sh", "gcloud run deploy ccs-parser --image x",
                    "gcloud run services update-traffic ccs-parser --to-latest", "vercel --prod",
                    "gh secret set SUPABASE_ACCESS_TOKEN --env production",
                    "gh workflow run deploy-supabase.yml --ref main", "gh pr merge 12",
                    "apps/ios/scripts/publish-build.sh", 'psql "$LEDGER_DB_URL" -c "select 1"',
                    "supabase db query --linked 'update x set y=1'",
                    "GH_TOKEN=$(gh auth token --user hussu97) gh api -X PUT repos/hussu97/cc-statement-scraper/x"]:
            self.assertEqual(bash(cmd), "ask", cmd)

    def test_reads_and_local_are_allowed(self):
        for cmd in ["supabase db push --dry-run", "supabase migration list --linked", "supabase db reset",
                    "supabase test db", "supabase start", "supabase functions serve",
                    "supabase gen types typescript --local", "gh run list", "gh pr view 3",
                    "GH_TOKEN=$(gh auth token --user hussu97) gh pr list -R hussu97/cc-statement-scraper",
                    "curl -s http://127.0.0.1:54321/functions/v1/worker", "pnpm check"]:
            self.assertEqual(bash(cmd), "allow", cmd)


class Destructive(unittest.TestCase):
    def test_denies(self):
        for cmd in ["rm -rf backend", "rm -rf ./backend/", "rm -r data/backups",
                    "rm -rf /Users/h/Documents/GitHub/scrapers/credit-card-scraper/backend",
                    "psql -c 'drop schema legacy cascade'", "psql -c 'DROP TABLE legacy.statements'",
                    "psql -c 'delete from legacy.profiles'", "supabase db reset --linked"]:
            self.assertEqual(bash(cmd), "deny", cmd)

    def test_allows(self):
        for cmd in ["rm -rf apps/web/dist", "rm -rf node_modules", "rm backend.txt", "ls backend/data"]:
            self.assertEqual(bash(cmd), "allow", cmd)


class Secrets(unittest.TestCase):
    def test_denies_printing(self):
        for cmd in ["cat supabase/functions/.env.production", "cat .env.cutover", "head -5 scraper/.env",
                    "grep PARSER_URL services/parser/.env.production", "cat apps/ios/Config/Secrets.Release.xcconfig",
                    "printenv", "env | grep KEY", "echo $SUPABASE_SECRET_KEY", "echo ${CRON_SECRET}",
                    "gh auth token --user hussu97"]:
            self.assertEqual(bash(cmd), "deny", cmd)

    def test_allows_shape_checks(self):
        for cmd in ["cut -d= -f1 supabase/functions/.env.production", "grep -c '^PARSER_URL=' .env.cutover",
                    "cat apps/web/.env.example", "cat apps/ios/Config/Secrets.example.xcconfig",
                    "set -a; source .env.cutover; set +a", "env FOO=1 pnpm test",
                    "git check-ignore -v supabase/functions/.env"]:
            self.assertEqual(bash(cmd), "allow", cmd)

    def test_read_tool(self):
        self.assertEqual(read("/repo/supabase/functions/.env.production"), "deny")
        self.assertEqual(read("/repo/apps/ios/Config/Secrets.xcconfig"), "deny")
        self.assertEqual(read("/repo/apps/web/.env.example"), "allow")
        self.assertEqual(read("/repo/CLAUDE.md"), "allow")


if __name__ == "__main__":
    unittest.main(verbosity=1)
