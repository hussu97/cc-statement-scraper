# Audit 07: Final pre-cutover verification

**Scope:** (1) a real-data re-run of the legacy import on the local stack with the final code, and
(2) clean-room checks from a fresh clone: every test suite, migrations from scratch, and all
migrations applied on top of a copy of the production schema and data.
**Branch:** `ledger-v2` @ `98f901c` for the code under test (`2248bd4` and `aecdb79` landed during the
run; they change only docs and the parser version string). **Date:** 2026-10-08.
**Method:** as in [02-data-parity.md](02-data-parity.md) (legacy fingerprints vs current v2 lines, legacy
debits vs `spend_series`).
**Privacy:** counts and aggregated AED only.

> Nothing was written to the production project or the GCS bucket. Part 1 wrote only to the shared local
> stack (`127.0.0.1:54322`). Part 2 used two throwaway stacks (`ledger-verify` on :545xx and
> `ledger-prodsim` on :546xx). Both were stopped with `--no-backup`, and the clone was deleted.

## Recommendation: GO, after one blocking fix

| # | Blocking | Item |
|---|---|---|
| FV-01 | **Yes** | Production's default privileges give every v2 table full grants to `anon` and `authenticated`. On the prod-shaped database, 2 of 503 pgTAP tests fail. One SQL statement fixes it (verified). |
| FV-02 | No, if the parser is deployed before the first canary | Re-parsing a document whose statement identity changes leaves genuine same-amount repeat purchases held as `ambiguous`. 2 lines / 65 AED, reproduced twice. |
| FV-03 | No | `period_overlap` reviews are not dismissed when the statement they name is superseded automatically (9 stale reviews). |
| FV-04 | No (process) | The shared local stack was running older bodies of 4 migrations that were edited in place. `migration up` cannot detect this. |
| FV-05 | No | Minor items: finalize report noise, CI Postgres image, `@sentry/cli` build script. |

Everything else passed:
- line parity is 100 % for every bank
- the three P0s from audit 02 are fixed on real data
- every test suite is green in a fresh clone
- all 23 migrations apply cleanly on the real production shape

## Part 1: real-data re-run (local stack)

### Setup

- `supabase migration up --local` reported nothing to apply. But migrations `…1000`, `…1600`, `…1700` and
  `…1800` had been edited after the local stack applied them (FV-04). I re-applied the four changed
  definitions from the files:
  - `private.reconcile_statement`
  - `public.resolve_review`
  - `private.validate_rule`
  - `private.apply_legacy_category_choices`

  The `1000` change is only a template name. Afterwards every function and index definition in
  `public`/`private`/`authz` matched a fresh `db reset` (md5 per definition, 115 functions).
- Restarted `functions serve` with the current code and started the parser from `services/parser` (both
  `/health` checks OK, parser `2026.10.0`, the same logic as `2026.10.1`). I stopped the parser afterwards.
- Ran `requeue_documents` for both imported profiles (75 + 12 documents), then drained the worker. One
  `worker?sync=1` call parsed all 87 documents in 24 s, and every queue ended empty.

### Results

**Documents:** 87 of 87 `parsed`. 0 failed (audit 02 had 2 `INGEST_23514`). 0 DLQ.

**Line coverage** (legacy fingerprint has a current v2 line):

| Profile | Bank | Legacy lines | In v2 (current) | Only superseded | Absent | Coverage |
|---|---|---|---|---|---|---|
| hussain | ADCB | 229 | 229 | 0 | 0 | 100 % (was 81 %) |
| hussain | ENBD | 360 | 360 | 0 | 0 | 100 % (was 89 %) |
| hussain | FAB | 1,091 | 1,091 | 0 | 0 | 100 % |
| hussain | SIB | 156 | 156 | 0 | 0 | 100 % (was 53 %) |
| tejasvie | MASHREQ | 1,233 | 1,233 | 0 | 0 | 100 % |

**Spend parity** (legacy Σ `amount_aed > 0` by transaction month vs v2 `spend_series`):

| Profile | Legacy AED | v2 AED | Δ | Months with \|Δ\| > 1 % |
|---|---|---|---|---|
| hussain | 200,053 | 200,652 | **+0.30 %** (was −12.1 %) | 9 of 24 |
| tejasvie | 130,795 | 130,795 | 0.00 % | 0 of 13 |

Every hussain month with a delta over 1 % breaks down line by line into known, expected differences:

| Month | Legacy | v2 | Δ | Explanation |
|---|---|---|---|---|
| 2025-08 | 13,249 | 13,737 | +488 | 2 FAB EUR rows legacy never parsed (parser fix) |
| 2025-11 | 26,933 | 22,120 | −4,813 | legacy phantom copy of the ENBD Dec-2025 statement (v2 correct) |
| 2025-12 | 10,932 | 10,597 | −335 | phantom −270, plus **2 lines (65 AED) held `ambiguous`** (FV-02) |
| 2026-02 | 11,348 | 13,931 | +2,583 | 6 FAB KWD rows (+489) and 11 SIB history lines legacy never had (+2,095) |
| 2026-03 | 11,196 | 9,617 | −1,579 | refund netted (−1,623, definition) and FX estimate on a null-AED line (+44) |
| 2026-04 | 4,102 | 3,358 | −744 | SIB finance charge categorised Cashback (income), BACKLOG DP-09 |
| 2026-05 | 7,673 | 7,324 | −349 | same as 2026-04 (DP-09) |
| 2026-06 | 10,270 | 13,915 | +3,645 | 28 SIB history lines legacy never had |
| 2026-08 | 4,045 | 5,686 | +1,642 | 21 SIB history lines legacy never had |

Totals:
- new lines +8,769 (FAB EUR/KWD 977, SIB history 7,792)
- phantom −5,084
- held −65
- DP-09 −1,442
- refunds −1,623
- FX estimate +44

These net to +598 (the 1 AED gap is rounding). 2026-07 (+62 = new SIB 410 − DP-09 349) is under 1 %.
Nothing is lost.

**Recon** (80 active statements, up from 78; the two ENBD January statements are back):

| | ok | warn | fail | n/a |
|---|---|---|---|---|
| ADCB | 21 | | | |
| ENBD | 20 | 1 (Dec-2025: `held_lines 2`, FV-02) | | |
| FAB | 16 | | 4 (`credits_match=false`, balance equation holds: DP-10) | |
| SIB history | | | | 6 |
| MASHREQ | | 12 (totals not extracted: DP-12) | | |

**Open reviews** (imported profiles):
- hussain: `period_overlap` 9 (FV-03), `ambiguous` 2 and `orphaned` 2 (FV-02)
- tejasvie: 0

The 150 `orphaned` reviews from audit 02 are gone.

**Null `amount_aed`:** 0 transactions. 3 carry an estimate.

**Duplicate-looking transactions** (same account, date, amount, currency, direction, description):
- hussain: ENBD 1 group / 2, FAB 5 / 15
- tejasvie: Mashreq 4 / 8

Every group comes from distinct rows of a single statement, and each row carries a legacy fingerprint, so
these are genuine same-day repeat purchases. v2 added no duplicates.

**Stale or bad-year statements** (runbook step 8 query 1, plus `period_start > period_end`): 0 for the
imported profiles.

**ENBD 2026-12-28:** **superseded.** The re-parse of the December PDF produced 2025-12-28, and
`retire_doc_from_statement` retired the bad-year statement. Remaining local clean-up:
- dismiss the 9 overlap reviews that name it (FV-03)
- resolve the 2 ambiguous lines with `{"link": <the score-100 candidate>}` (FV-02)

The local test profile `real6feeed22` held a second active 2026-12-28 copy. I re-parsed it
(`requeue_documents`) and it reproduced exactly the same outcome.

**Finalize** (`migrate_legacy.py --target local --step finalize`, dry run, then `--apply`):
- runs cleanly (DP-05 is fixed)
- `legacy_lines_missing = 0` and `legacy_aed_missing = 0` for every bank
- `months_with_delta`: ADCB 0, ENBD 2, FAB 2, SIB 5, MASHREQ 0, matching the table above
- `legacy_missing_lines()` returns 0 rows
- `legacy_unmatched_choices()` returns 0 rows
- 2,664 choice applications, all `agreed`

The report also lists the local demo profiles, which have no legacy data (FV-05).

## Part 2: clean-room checks (fresh clone)

| Check | Result |
|---|---|
| `pnpm install --frozen-lockfile` | OK. Warning: `@sentry/cli` build script ignored (FV-05) |
| tokens check | OK |
| web lint / test / build | OK / 17 files, 159 tests / OK |
| `deno test -A .` (functions) | 91 passed, 0 failed, 1 ignored (opt-in e2e) |
| parser: ruff, pytest | clean; 180 passed, 8 skipped (private sample PDFs / golden files absent) |
| scraper pytest | 135 passed |
| `scripts/tests` | 12 passed |
| LedgerKit `swift test` | 114 tests in 22 suites passed |
| `xcodegen generate` | no drift against the committed `Ledger.xcodeproj` |
| `xcodebuild` (iPhone 17 Pro simulator, `CODE_SIGNING_ALLOWED=NO`) | BUILD SUCCEEDED, 23 warnings (`nonisolated(unsafe)` redundancy, 2 deprecations) |
| isolated stack: `supabase start` + `db reset` | all 23 migrations and the seed applied |
| `supabase test db` | 10 files, 503 tests, PASS |
| types drift (`gen types` vs `packages/db-types`) | none |

### Migrations on the production shape

Setup:
- a throwaway stack pinned to production's service versions (`postgres:17.6.1.104`, gotrue v2.197.0,
  storage v1.77.5, postgrest v14.5)
- loaded `prod-schema-20261008T094435Z.sql` and `prod-data-…sql`
- added an event trigger on `public.rls_auto_enable()`. The dump has the function but not the trigger
  (schema dumps omit event triggers), so I assumed prod has it. With it, every new `public` table gets RLS.
- applied the 23 migrations with `supabase migration up` (the `db push` path)

Result:
- **All 23 applied cleanly.**
- `legacy` holds 21 tables, 19 sequences and 10 enums.
- Row counts match the backup: statements 94, statement_lines 3,069, pdf_files 380, category_rules 198.
- `anon`, `authenticated` and `service_role` have no USAGE on `legacy`.
- 10 cron jobs and 6 queues exist.
- `public.rls_auto_enable()` is the only legacy object left in `public` (harmless).

Then I fingerprinted the schema against a fresh migrate. The fingerprint covered relations, RLS flags,
columns, policies, function bodies and ACLs, table grants, indexes, triggers and cron jobs. That
comparison found FV-01.

## Findings

### FV-01 (blocking): production default privileges re-open table grants

**Cause.** Production was created with Supabase's older defaults:

```sql
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role
```

The source is the schema dump, lines 1885–1888. The local and CI stacks start with restricted defaults
(`anon=Dxtm`, `authenticated=Dxtm`). The migrations grant only what clients need, often per column, and
never revoke table-level privileges. So `db push` on prod gives every v2 table:
- `anon`: SELECT, INSERT, UPDATE and DELETE
- `authenticated`: table-wide INSERT, UPDATE and DELETE

**Repro.** Run the "migrations on the production shape" setup above, then `supabase test db`. Result:
`01_rls.test.sql` fails:
- test 14, "token hashes are not readable by clients": an owner can select `service_tokens.token_hash`
- test 21, "anon has no table access": RLS still returns 0 rows

**Impact.**
- RLS still blocks `anon` from every row, and blocks writes that have no matching policy.
- The column-level UPDATE limits are lost on `transactions`, `accounts`, `cards`, `categories`,
  `profiles`, `insights` and `recurring_series`. An owner can rewrite any column of their own rows, for
  example `amount_aed` or `status`, through PostgREST and bypass the ledger RPCs.

**Fix (verified).** Run this before `supabase db push`, either in runbook step 4 or as the first statement
of `20261008000000_quarantine_legacy.sql`:

```sql
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated;
```

With that statement, the prod-shaped run passes all 503 pgTAP tests. The only grant differences left are
function ACLs, which are cosmetic: every function already has `PUBLIC` EXECUTE by design (see the
`…0100` note), and all 15 service-only RPCs call `assert_service_role()`.

### FV-02 (P1): re-parse relink holds same-amount repeat purchases

**Where:** `supabase/migrations/20261008001600_audit_ingest_and_review.sql:469-479`
(`match_statement_lines`, `v_conflict`).

**What happens.** A re-parse moves a document's lines to a new statement: here, the ENBD year fix moved
2026-12-28 to 2025-12-28. The matcher then sees two orphaned transactions per line: same merchant and
amount, one day apart, scores 100 and 95. They fall within the 15-point window and have different
`txn_sig`, so both lines get `ambiguous` reviews. Their old transactions stay `orphaned`. The result is
65 AED missing from spend until a user resolves 4 reviews.

**Repro.** Deterministic. It happened for hussain and again for `real6feeed22`.

**Fix.**
- Prefer the candidate whose deactivated evidence line has the same `line_key`.
- Or don't flag a conflict when the best candidate has `ddays = 0` and the rival does not.

**Cutover impact.** On a clean run, each PDF is parsed once by the fixed parser, so this does not occur.
It does affect runbook step 8's re-parse remediation and any future parser re-parse.

### FV-03 (P2): stale `period_overlap` reviews

**Where:** `…1600:838-840` (`supersede_statement`) and `:878-881` (`retire_doc_from_statement`).

**What happens.** Both functions dismiss only reviews whose *subject* is the retired statement, not
reviews that list it as a *candidate*. After the automatic supersede, 9 reviews still point at a
superseded statement.

**Fix.** Also dismiss open `period_overlap` reviews whose candidates are all no longer active. Until
then, the runbook needs a "dismiss the overlap reviews" step for the auto-superseded case too.

### FV-04 (process): the shared local stack drifted from edited migrations

`supabase migration up` matches migrations by version only. The four migrations edited after they were
applied locally were not re-run. That was harmless here (fixed by hand, then checked equal to a fresh
reset).

The pre-cutover rehearsal must start from `supabase db reset` (or a fresh stack), not from a stack that
already has a version applied. Prod has applied none of these versions, so prod is not affected.

### FV-05 (P3)

- `legacy_parity_report()` (`…1800:367-374`) and the finalize `documents:` line
  (`scripts/migrate_legacy.py:352`) include profiles that have no legacy data. Locally that means the
  demo profiles. In prod, profiles created before finalize would add noise.
- The clean-room stack (and CI) ran Postgres `17.6.1.143`, the CLI default, while prod is `17.6.1.104`.
  The prod-shape run above covers `.104`, but consider pinning CI.
- pnpm 10 skips the `@sentry/cli` build script. Check that the Vercel build actually uploads source maps,
  or allow it with `pnpm.onlyBuiltDependencies`.

## Fix status

Fixed on 2026-10-08 (uncommitted on `ledger-v2` at the time of writing). Nothing touched production.

| # | Status | Change |
|---|---|---|
| FV-01 | **Fixed** | `…0000_quarantine_legacy.sql` now starts with `alter default privileges for role postgres in schema public revoke all on tables` (and `on sequences`) `from anon, authenticated`, before any table is created. `all` also covers MAINTAIN, which closes BACKLOG DB-30. Defence in depth: the new final migration `…2100_reassert_client_grants.sql` revokes everything from `anon` and `authenticated` on every `public` table, view and sequence, then replays the intended grant statements. New guard `11_privileges.test.sql`: no client default privileges in `public`; `anon` holds nothing (ACLs and effective privileges); `authenticated` has no TRUNCATE/REFERENCES/TRIGGER, no table-wide UPDATE/INSERT/DELETE on ledger and identity tables, and cannot select `token_hash` or `sms_templates.examples`; plus the exact privilege matrix (`set_eq`, 94 entries), which must be updated with any client grant change. |
| FV-02 | **Fixed** | `…2000_fv_matcher_and_reviews.sql` redefines `private.match_statement_lines`. A candidate has *lineage* when the transaction was previously evidenced by the same line, by a line with the same `line_key` + `occurrence`, or by a line of the same source document with the same date and amount. Lineage pairs (score ≥ 75) are matched first, and a rival without lineage is not a conflict. Also, for a same-day pair, a rival ≥ 1 day away is not a conflict when it has its own same-day partner that scores at least as well. A line between two equally likely transactions is still held. |
| FV-03 | **Fixed** | Same migration: trigger `statements_dismiss_stale_reviews` (after `status` leaves `active`, by any path) calls `private.dismiss_stale_statement_reviews`. It dismisses open reviews whose subject is the statement (`statement_superseded`) and open `period_overlap` reviews with no active candidate left (`overlap_candidates_superseded`). A one-off pass dismisses reviews that are already stale. |
| FV-04 | **Documented** | PRODUCTION.md's rehearsal bullet now requires starting from `supabase db reset` and explains how to rehearse against prod's grants. BACKLOG.md has a new P3 row FV-04 for a CI guard that fails on edits to applied migrations. |
| FV-05 | Open | Unchanged. |

**Verification.**
- **FV-01 reproduced and fixed on a throwaway stack** (`ledger-fvfix`, ports 547xx, a scratch clone). A migration sorted before `…0000` emulated production's defaults (`grant all on tables/sequences/functions to anon, authenticated, service_role`, as in the prod dump).
  - Old migrations: `01_rls` tests 14 and 21 fail. 2 of 503 fail, exactly as in the report.
  - Fixed migrations: 12 files, **533 tests, PASS**.
  - Only `…2100`, without the `…0000` change: the matrix and every grant guard pass. Only the default-privileges guard fails, as intended.
  - The stack was stopped with `--no-backup` and the clone was deleted.
- **FV-02 and FV-03 regressions** are in `12_final_verification.test.sql`:
  - the reported pattern: a bad-year statement with two same-amount purchases on consecutive days, plus an overlapping statement whose `period_overlap` review names it, then a re-parse with the corrected year
  - consecutive-day SMS purchases matched by a later statement
  - a still-ambiguous control
  - On the old code, 12 of 19 tests fail. On the new code, all pass.
- **Shared local stack, no reset:**
  - I ran the new `alter default privileges` statements from `…0000` by hand.
  - `supabase migration up --local` applied `…2000` and `…2100`.
  - `supabase test db`: 12 files, 533 tests, PASS.
  - `pnpm db:types`: no change.
  - The one-off FV-03 pass dismissed the 9 stale `period_overlap` reviews.
  - The FV-02 lines that were already held stay held, because the matcher skips lines under an open review. 5 `ambiguous` and 4 `orphaned` reviews remain open across all local profiles. Resolve them with `{"link": …}` as described above. New re-parses no longer create them.
