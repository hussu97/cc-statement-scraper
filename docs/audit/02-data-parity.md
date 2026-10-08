# Audit 02: Legacy → v2 data parity (cutover rehearsal on real data)

**Scope:** replaying the real legacy production data through the v2 cutover path (`scripts/migrate_legacy.py`,
`supabase/migrations/20261008000950_legacy_import.sql`, the `worker` Edge Function and the parser) on the
**local** stack, then comparing legacy and v2 line by line.
**Branch:** `ledger-v2` @ `4ec697c`. **Date:** 2026-10-08.
**Inputs:** prod backup `data/backups/prod-{schema,data}-20261008T094435Z.sql`; legacy PDFs from the
`ccs-platform-pdfs` bucket (read-only copy, deleted after the run).
**Privacy:** this document contains only counts, aggregated AED sums and anonymised descriptions. No merchant
names, card numbers or individual transaction amounts.

> Nothing was written to the production project or the bucket. All writes went to the local stack
> (`127.0.0.1:54322` / `:54321`). The imported data is left in place locally: profiles `hussain` and `tejasvie`,
> 87 legacy documents in Storage, and a populated `legacy` schema.

## Summary

| Severity | Count |
|---|---|
| P0: data loss or wrong totals, must fix before cutover | 3 |
| P1: fix before cutover if possible | 5 |
| P2: soon after | 8 |
| P3: nice to have | 6 |

**Headline:** Mashreq (tejasvie) and FAB (hussain) migrate with exact parity: the same lines, the same AED and
the same months. ADCB, SIB and ENBD do not. **v2 loses 189 statement lines that the PDFs contain** (155 that
legacy had, plus 34 from PDFs legacy never parsed). In hussain's analytics that is **19,412 AED of legacy debits**:
- ADCB: 44 lines. A second, card-less ADCB PDF replaces the real statement of the same date.
- SIB: 107 lines. A newer history extract supersedes the older extract's lines for the same cycle.
- ENBD: 38 lines. The bank prints the wrong year at the Dec/Jan boundary and ingest rejects the document.

hussain's total spend is −12.1 % vs legacy. Without the three P0s it would be about −2.4 %, which is fully
explained by v2's spend definition and by legacy bugs v2 fixes.

### Key numbers

| | Legacy | v2 |
|---|---|---|
| `pdf_files` rows / unique PDFs per profile | 380 / 87 | 87 documents uploaded (293 byte-identical duplicates skipped, 0 missing) |
| Documents parsed / failed | – | 85 parsed / 2 failed (`INGEST_23514`) |
| Statements (hussain + tejasvie) | 94 (82 + 12) | 78 active (66 + 12) |
| Statement lines | 3,069 (1,836 + 1,233) | 2,939 posted transactions (1,706 + 1,233) |
| Legacy lines present in v2 (by `legacy_fingerprint`) | – | 2,914 of 3,069 (FAB 100 %, Mashreq 100 %, ENBD 89 %, ADCB 81 %, SIB 53 %) |
| hussain debits (legacy `amount_aed > 0`) vs v2 `spend_series` | 200,053 AED | 175,869 AED (−12.1 %) |
| tejasvie debits vs v2 spend | 130,795 AED | 130,795 AED (0.0 %) |
| Category agreement on matched lines | – | 95.6 % (hussain 100 %, tejasvie 89.5 %); every disagreement is a v2 improvement |
| Uncategorised (rules only → after LLM) | 8.9 % / 18.7 % | 9.4 % / 8.9 % → 2.3 % / 1.7 % |
| Recon (78 active statements) | – | ok 60 · warn 12 · fail 6 |
| Open match reviews | – | 150 `orphaned` · 8 `period_overlap` |
| Transactions with null `amount_aed` | – | 0 (3 null-AED FX lines received an estimate) |

## Method

1. **Legacy schema.** I took the 10 enum types and the 21 legacy tables (with their sequences, defaults,
   constraints and indexes) from the schema dump and rewrote `"public".` → `"legacy".`. I left out the
   extensions, the `rls_auto_enable` event trigger and the grants. I loaded the public-schema `INSERT`s and
   `setval`s from the data dump into `legacy.*` in one transaction. The v2 `public` tables were not touched.
   Row counts: statements 94, statement_lines 3,069, pdf_files 380, category_rules **198** (the brief expected
   199), profiles 2, categories 19, category_overrides 0, runtime_settings 14, mailboxes 2, routes 3.
2. **Metadata.** `migrate_legacy.py --step metadata --apply` with the two member emails. The profile keys do not
   collide with the seed profiles (`demo`, `household`, `real6feeed22`).
   **Secrets.** `--step secrets --apply`, with only `LEGACY_FERNET_KEY` taken from `.env.cutover`.
3. **PDFs.**
   - Started the local parser (`services/parser/.venv`, uvicorn on `0.0.0.0:8080` with its `.env`).
     `functions serve` was already running.
   - Copied the bucket (391 objects) into the scratchpad.
   - Ran `--step pdfs --apply` with `LEGACY_STORAGE=local`, local `SUPABASE_URL`, `LEDGER_DB_URL` and the local
     service-role key.
   - Called `POST /functions/v1/worker?sync=1` until no legacy document was `queued` or `parsing`.
4. **Finalize.** `--step finalize --apply` crashed (DP-05). I then ran `private.apply_legacy_category_choices()`
   by hand. For the parity report I used a corrected copy of `legacy_parity_report()` with `::text` casts, run in
   a temp table. I did the deep diff in SQL:
   - statements matched on (profile, bank, `statement_date`)
   - lines matched on `legacy.statement_lines.fingerprint` ↔ `statement_lines.legacy_fingerprint` (current lines)
   - transactions through `transaction_evidence`
5. **Analytics.** I compared v2 `spend_series` (identical to `overview().spend`, checked for 5 months) with legacy
   debits by `transaction_date` month, and decomposed every difference line by line.
6. **LLM.** `select private.enqueue_llm_categorize()` (12 batches), then drained via the worker
   (`claude-haiku-5-5`).
7. **Cleanup.** Deleted the PDF copy, the parser-output dumps and the load script. Stopped the parser I started.

## Parity tables

### Per profile / bank (all months)

Legacy AED is the net sum of `amount_aed` (negative = credit). v2 AED is the posted transactions, debit − credit.

| Profile | Bank | Legacy lines | v2 posted | Legacy net AED | v2 net AED | Legacy debit AED | v2 debit AED | Months with Δ |
|---|---|---|---|---|---|---|---|---|
| hussain | ADCB | 229 | 185 | −1 | 2 | 35,552 | 27,966 | 6 / 22 |
| hussain | ENBD | 360 | 310 | 1,079 | −1,543 | 49,827 | 40,684 | 6 / 23 |
| hussain | FAB | 1,091 | 1,091 | −526 | −526 | 91,381 | 91,381 | 0 / 21 |
| hussain | SIB | 156 | 120 | 1,368 | −11,222 | 23,293 | 18,205 | 5 / 7 |
| tejasvie | MASHREQ | 1,233 | 1,233 | 942 | 942 | 130,795 | 130,795 | 0 / 13 |
| **total** | | **3,069** | **2,939** | 2,862 | −12,348 | 330,848 | 309,031 | 17 / 86 |

### Line coverage by legacy fingerprint

| Bank | Legacy lines | In v2 (current) | Only in superseded v2 lines | Absent from v2 | v2 current lines not in legacy |
|---|---|---|---|---|---|
| ADCB | 229 | 185 | **44** (DP-01) | 0 | 0 |
| ENBD | 360 | 322 → 310 v2 lines¹ | 0 | **38** (DP-03) | 0 |
| FAB | 1,091 | 1,091 | 0 | 0 | 0 |
| SIB | 156 | 83 | **73** (DP-02) | 0 | 37² |
| MASHREQ | 1,233 | 1,233 | 0 | 0 | 0 |

¹ 12 legacy lines are a phantom copy of the Dec-2025 ENBD statement. Legacy stored the same PDF twice, as
2025-12-28 and 2026-12-28. v2 correctly keeps one copy.
² From two SIB history PDFs that legacy never turned into statements. v2 also supersedes 34 more lines from those
PDFs (DP-02).

Field-level diffs on the 2,914 matched lines:
- dates: 0 month shifts (1 same-month date difference)
- direction: 0 diffs; legacy sign matches v2 direction everywhere
- AED: 0 diffs
- currency: 0 diffs
- `amount_original`: 4 diffs, all fingerprint-collision artefacts on sub-1-AED FX rows (AED identical)
- kind: 27 diffs, all legacy `fee` → v2 `purchase` (22 café purchases that legacy called fees because of a
  substring match) or v2 `interest` (5 finance-charge lines)

### Statements matched on (bank, statement_date)

| Bank | Matched | Legacy only | v2 only | Note |
|---|---|---|---|---|
| ADCB | 21 dates | 0 | 0 | Legacy has 34 statements on 21 dates: 13 are a second, card-less ADCB PDF with 0 lines (DP-01) |
| ENBD | 19 | 3 | 0 | 2 Jan statements failed (DP-03). Dec-2025 is dated 2026-12-28 in v2, as in legacy's phantom (DP-04). |
| FAB | 20 | 0 | 0 | Split over 2 v2 accounts at the card replacement (DP-20) |
| SIB | 6 | 0 | 0 | All `history_extract` |
| MASHREQ | 12 | 0 | 0 | |

### hussain monthly spend: legacy dashboard vs v2 `spend_series` / `overview`

Legacy = Σ `amount_aed > 0` by `transaction_date` month. The components below sum exactly to the v2 figure,
with a 0.00 residual every month. The columns are:
- **lost**: legacy debits missing from v2's current lines
- **phantom**: legacy duplicate lines
- **excl.**: debits v2 excludes by category kind
- **refunds**: v2 nets refunds against spend
- **new**: v2 lines that legacy lacked
- **FX est.**: a null-AED line that now has an estimate

Months not listed match exactly.

| Month | Legacy | v2 | Δ % | Lost | Phantom | Excl. | Refunds | New | FX est. | Explanation |
|---|---|---|---|---|---|---|---|---|---|---|
| 2024-12 | 3,036 | 2,884 | −5.0 | 151 | | | | | | ENBD Jan-2025 statement failed (DP-03) |
| 2025-01 | 3,632 | 1,119 | −69.2 | 2,513 | | | | | | Same (21 lines) |
| 2025-11 | 26,933 | 22,120 | −17.9 | | 4,813 | | | | | Legacy phantom ENBD copy (v2 correct). ±135 FAB collision artefact nets to 0 with Dec. |
| 2025-12 | 10,932 | 10,499 | −4.0 | 163 | 270 | | | | | Phantom ENBD copy (v2 correct) + ENBD Jan-2026 statement failed (DP-03) |
| 2026-01 | 5,983 | 4,751 | −20.6 | 1,232 | | | | | | ENBD Jan-2026 statement failed (DP-03) |
| 2026-03 | 11,196 | 9,617 | −14.1 | | | | 1,623 | | +44 | One SIB refund netted (definition). FX estimate on a null-AED SIB line. |
| 2026-04 | 4,102 | 3,297 | −19.6 | 60 | | 744 | | | | Finance charge categorised Cashback (income) and excluded (DP-09). ADCB line lost (DP-01). |
| 2026-05 | 7,673 | 4,473 | −41.7 | 3,200 | | | | | | 30 SIB lines superseded (DP-02) + 2 ADCB (DP-01) |
| 2026-06 | 10,270 | 10,556 | +2.8 | 296 | | | | 582 | | ADCB lost; SIB new lines from an extract legacy never parsed |
| 2026-07 | 9,364 | 5,089 | −45.7 | 4,685 | | | | 410 | | 34 SIB lines superseded (DP-02) |
| 2026-08 | 4,045 | 5,066 | +25.3 | 621 | | | | 1,642 | | 19 ADCB lines lost (DP-01); 21 new SIB lines |
| 2026-09 | 9,278 | 2,787 | −70.0 | 6,490 | | | | | | **The whole ADCB Sep-2026 statement (14 debits) was replaced by an empty PDF** (DP-01) |
| **Total** | 200,053 | 175,869 | −12.1 | 19,412 | 5,083 | 744 | 1,623 | 2,635 | 44 | |

Lost by bank: ADCB 39 debits / 7,587 AED · ENBD 32 / 4,059 · SIB 65 / 7,766.
tejasvie: legacy 130,795 = v2 130,795 (no refunds, no excluded categories, no lost lines).

## Findings

| ID | Sev | Category | Location | Title |
|---|---|---|---|---|
| DP-01 | **P0** | data loss | `…0700_ingest_and_match.sql:133-165` `resolve_statement_account`, `:704-730`, `:781-797` `ingest_one_statement`; `services/parser/ccs_parser/banks/adcb.py:48,95` | A card-less ADCB PDF replaces the real statement of the same date. Its lines are superseded and the transactions orphaned (44 lines, 5 statements, the result depends on parse order). |
| DP-02 | **P0** | data loss | `…0700:704-730, 781-797` (applied to `kind='history_extract'`); `…0300` `statements_history_identity_uq` | A newer SIB history extract for the same cycle supersedes every line of the older extract that it does not repeat (107 lines lost, 54 % of SIB) |
| DP-03 | **P0** | data loss | `services/parser/ccs_parser/banks/enbd.py:124-128`; `…0300:75` `statements_check` | ENBD prints the wrong year at the Dec/Jan boundary. Jan statements fail `INGEST_23514` and are never ingested (2 documents, 38 lines). |
| DP-04 | P1 | wrong data | same as DP-03 | The ENBD Dec-2025 statement is stored as **2026-12-28** with a 13-month period. Overview `latest_statement`, `due_date` and utilisation for ENBD are wrong, and there are 8 bogus `period_overlap` reviews. |
| DP-05 | P1 | runbook | `…0950:235-271` `legacy_parity_report`; `scripts/migrate_legacy.py:235-251` | `--step finalize` crashes (`varchar` vs `text`) and rolls back, so legacy category choices are not applied (= DB-11). The report compares month sums only, so it cannot show line loss. |
| DP-06 | P1 | UX/data | consequence of DP-01/02; `…0700` `refresh_transaction` | 150 open `orphaned` reviews on day 1 (106 history, 44 statement). The orphaned transactions drop out of spend. |
| DP-07 | P1 | parser (pre-existing) | `services/parser/ccs_parser/banks/fab.py:280-345` | The FAB parser skips the rows of a second section that has its own subtotal: about 977 AED of debits in 2 statements (legacy identical). v2 recon catches it. |
| DP-08 | P1 | recon gap | `…0700:606-660` `reconcile_statement` | ADCB statements are checked only by the balance equation, so the statement DP-01 hollowed out still reports `ok`. History extracts get no checks at all. |
| DP-09 | P2 | categorisation | `…0650_seed_defaults.sql:230`; `…0800_analytics.sql:9-24` `v_spend` | The seed rule maps Islamic-card finance charges to Cashback (`income`), so v2 excludes the debit from spend (744 AED) |
| DP-10 | P2 | parser totals | `services/parser/ccs_parser/totals.py:131-132, 178-179` | FAB `total_credits` is short by whole payment amounts in 4 statements → false recon `fail` (the balance equation holds) |
| DP-11 | P2 | parser | `services/parser/ccs_parser/banks/mashreq.py:28-37, 218-256` | Mashreq FX rows are not recognised (38 transactions). They are stored as AED, with the original currency, amount and reference left in the description. That creates 36 one-off merchants and makes `fx_spend` blind to them. |
| DP-12 | P2 | recon gap | `totals.py` (no Mashreq summary) | All 12 Mashreq statements are `warn: totals not_extracted`, so 42 % of all lines have no completeness check |
| DP-13 | P2 | runbook / safety | `.env.cutover`; `scripts/migrate_legacy.py:64-72, 173-174` | `.env.cutover` holds the **production** `SUPABASE_URL` and service-role key. A rehearsal that sources it writes to prod, and the script has no target guard or confirmation. |
| DP-14 | P2 | runbook | legacy `runtime_settings`; `migrate_legacy.py:56-61` | Legacy has no Gmail OAuth app credentials (only the Microsoft ones). tejasvie's Gmail refresh token migrates, but cannot be used until `GMAIL_OAUTH_CLIENT_*` are set by hand. |
| DP-15 | P2 | concurrency | `…0700:109-130` `ensure_card`, `:133-165` | Bulk backfill hits `23505` on concurrent card inserts (4 events) and one `40P01` deadlock. They retry fine, but each retry waits 300 s of VT, and the same race can create duplicate accounts when last4 is null. |
| DP-16 | P2 | runbook | `migrate_legacy.py:171-232`; worker reads 3 at a time | The script's careful upload order (statements first, oldest first, history last) has no effect because the worker parses in parallel. That is why DP-01's outcome is non-deterministic. |
| DP-17 | P3 | runbook | `migrate_legacy.py:182` | `is_history` tests `statement_reference LIKE 'AUTO-SIB-%'`. That is the fallback reference of **every** legacy statement for that bank (every legacy reference is `AUTO-<BANK>-…`), so it is right only by coincidence. |
| DP-18 | P3 | data | GCS bucket | 10 bucket objects are not in `pdf_files`: 9 are byte-identical to migrated PDFs. One encrypted staging PDF was never ingested by legacy or v2 and needs a manual decision. |
| DP-19 | P3 | import | `…0950:224-228` | Choices whose category name doesn't resolve (9 lines on a legacy typo category) are still stamped `applied_at`. 136 choices never meet a line (lost lines and phantom), so the nightly helper cron never stops (see DB-12). |
| DP-20 | P3 | model | `…0700:133-165` | The FAB card replacement creates a second FAB account (6 + 14 statements), which splits `statement_cycles` and utilisation history |
| DP-21 | P3 | data | legacy `fingerprint` | Legacy fingerprints collide for genuine same-day repeat purchases (FAB 7 groups / 19 lines, Mashreq 5 / 10). Fingerprint-keyed choices can cross-apply. v2 keeps every row, which is correct. |
| DP-22 | P3 | ops | `…0900:240-273` `enqueue_llm_categorize`; worker | On a shared local stack, a rehearsal LLM run also categorises the demo profiles' merchants and processes their `sms_fallback` queue (3 demo SMS were sent to Claude) |

## P0

### DP-01: A card-less ADCB PDF replaces the real ADCB statement

On 7 of the 21 ADCB statement dates, legacy holds two PDFs. One is the real card statement with transactions. The
other is a second ADCB document with:
- a fully masked card number
- a different holder line and card type
- different opening and closing balances
- the same statement date, and **no transaction rows**

The ADCB parser's `_CARD_RE` doesn't match the fully masked number, so last4 stays `"0000"` and the contract
sends `null`. `resolve_statement_account` then falls back to "the only active ADCB account". `ingest_one_statement`
finds the active statement for `(account, statement_date)`, re-points it at the new document, and **supersedes
every line that the new (empty) payload lacks**. Those lines' evidence is deactivated, and their transactions
become `orphaned`.

Results in this run:
- 5 statements hollowed out, 44 lines and 39 debits lost (7,587 AED). This includes the entire Sep-2026
  statement (−70 % that month).
- 7 parsed documents end up with no statement at all.
- Which document wins depends on which finishes last. The worker parses 3 at a time, so a production run can
  lose more or fewer lines.
- Recon still says `ok` (DP-08), and the overview shows the empty card's balance as ADCB's latest statement.

**Fix:**
- Never let an incoming statement replace an existing one when the card identity differs. Key the identity on
  (account, statement_date, primary card), or refuse the single-account fallback when the existing statement has
  a known card.
- Treat "0 lines and a `No … rows matched` warning" as non-authoritative: open a review instead of superseding.
- Extend `_CARD_RE` to fully masked numbers. Model the second ADCB product as its own account.
- Add a regression test with two ADCB PDFs that share a date.

### DP-02: SIB history extracts overwrite each other

SIB history PDFs are rolling windows. v2 maps every extract to one `history_extract` statement per SIB cycle
(`statements_history_identity_uq`). A later extract that covers only part of a cycle (for example, only its last
week) replaces the earlier extract's statement and supersedes all lines it does not repeat. I checked: none of
the 107 superseded SIB lines has a twin (same date, amount and direction) among the current lines. These are
real transactions, not duplicates.

Results:
- 107 SIB lines lost, 54 % of all unique SIB transactions seen across the 5 PDFs: 73 that legacy had and 34
  that only v2 parsed.
- 7,766 AED of legacy debits lost, mostly May–Jul 2026 (−42 % and −46 %).
- 106 orphaned transactions.

The parity report's assumption that "SIB history duplicates disappear" doesn't hold for this data. Legacy had **no**
SIB double count (no repeated fingerprints).

**Fix:** make history ingestion additive. For `kind='history_extract'`, insert unseen `line_key`s and never
supersede on absence. Supersede only when a line is replaced by a statement line (the matcher already links them).

### DP-03: ENBD year-boundary statements are rejected

The PDFs literally print `Statement Period: 29-Dec-25 to 28-Jan-25`: the start year is wrong on January
statements. `enbd.py` parses both dates literally, so `period_start > period_end`, and `statements_check` fails
the whole document (`INGEST_23514`, permanent). Two January statements are lost: 38 lines and 32 debits
(4,059 AED, Dec 2024 to Jan 2025 and Dec 2025 to Jan 2026).

**Fix:** when start > end, move the start back one year. Validate that the period contains the transaction dates.
Add the two real layouts to the golden tests.

## P1

### DP-04: ENBD December statement dated a year in the future

The December PDF prints `29-Nov-25 to 28-Dec-26`, so v2 stores the statement on 2026-12-28 (the same bug legacy
had, where it also double-counted 12 lines that v2 correctly dedupes by sha256). The consequences:
- `overview().accounts[ENBD].latest_statement` is this future statement, with a due date that is earlier than its
  statement date
- utilisation is computed from it
- 8 later ENBD statements carry an open `period_overlap` review against it

**Fix:** same as DP-03 (clamp the end year to the transactions or the due date). Also reject
`statement_date > today + 31 days` at ingest.

### DP-05: Finalize cannot run

`legacy_parity_report()` returns `legacy.profiles.key` and `legacy.statements.bank_code`, which are `varchar`,
where the function declares `text`. The error aborts `step_finalize`, which runs
`apply_legacy_category_choices()` in the same transaction, so nothing is applied. With `::text` casts the report
runs, but it compares only month sums. It would show ADCB, SIB and ENBD deltas without saying they are lost
lines.

**Fix:**
- Add the casts (see DB-11).
- Commit the category step before the report.
- Add a line-level section: legacy fingerprints absent from current v2 lines, per bank. Fail the step if that
  number is non-zero and not explained.

### DP-06: 150 orphaned-transaction reviews on day 1

These are created by DP-01 and DP-02. Each orphaned transaction is excluded from spend and opens a review the
owner cannot meaningfully resolve. They disappear once DP-01 and DP-02 are fixed and the documents re-ingested.

### DP-07: FAB rows skipped in a second section (pre-existing)

In 2 of 20 FAB statements, the statement's own debit total exceeds the parsed debits by exactly the subtotal of
a second block of rows (6 dated rows in one statement, about 977 AED over both). Legacy has exactly the same
lines, so this is not a cutover regression. It is a real gap that v2's reconciliation exposes for the first time
(`fail`, `debits_match=false`, `balance_equation=false`).

**Fix:** the section/card switch handling in `fab.py:280-345` must keep parsing rows after an intermediate
`Total` line.

### DP-08: Reconciliation cannot see DP-01 or DP-02

- ADCB totals extraction yields only opening and closing balances. A hollowed statement carries the *other*
  card's balances, which are self-consistent with zero lines, so recon stays `ok`.
- History extracts get only `line_count` and sums, which are always `ok`.

**Fix:** after a replace, flag any statement whose line count drops by more than 50 %, or whose card changes. For
history extracts, compare the line count with the previous version.

## P2 / P3 notes

- **DP-09.** The seed rule `MURABAHA PROFIT → Cashback`. On an Islamic card this is a finance charge (a debit). As
  `Cashback` is `income`, `v_spend` drops it: 744 AED once. Legacy used the same category but counted all
  debits. Fix: map it to a fee/charges spend category, or add a `direction=credit` condition.
- **DP-10.** The FAB `total_credits` extracted is lower than the parsed credits by round payment amounts in 4
  statements, while the balance equation holds. The summary block evidently splits payments from other credits.
  This causes a false `fail`.
- **DP-11 / DP-12.** Mashreq FX rows are not recognised (the original currency and amount end up in the
  description), and Mashreq totals are never extracted. AED totals are still correct. The parity comment
  "Mashreq FX rows gain an AED estimate" does not happen with this data: Mashreq has no rows flagged as FX in
  either system.
- **DP-13.** For rehearsals, keep `.env.cutover` free of prod URLs and keys. Alternatively, make
  `migrate_legacy.py` print the target host and require `--i-mean-production` when it is not `127.0.0.1`.
- **DP-14.** Add a runbook line: set `GMAIL_OAUTH_CLIENT_ID/SECRET` from the Google Cloud console before the
  Gmail mailbox can sync. The secrets step reports only the MS app credentials.
- **DP-15.** In `ensure_card` and `resolve_statement_account`, use `insert … on conflict do nothing` + re-select
  (or an advisory lock per profile+bank).
- **DP-16.** Either set the worker's parse batch size to 1 during the backfill, or make ingestion
  order-independent (which DP-01 and DP-02 require anyway).

## Runbook problems hit during steps 1–4

1. Loading the legacy data needed a hand transform. The real path, `20261008000000_quarantine_legacy.sql` via
   `db push`, has never been exercised on a copy of the prod schema. **Rehearse `supabase db push` against a
   restored prod backup (or a Supabase branch) before the freeze.**
2. `.env.cutover` targets production (DP-13). I extracted only `LEGACY_FERNET_KEY`.
3. `--step finalize` crashes (DP-05). I applied the choices by hand: 11 transactions got a manual category.
4. Draining took about 9 minutes for 87 documents. Five transient ingest errors each waited the 300 s VT
   (DP-15).
5. The worker run also processed 3 queued demo `sms_fallback` messages and, in step 6, the demo profiles' LLM
   batches (DP-22).

## Step details

**Documents.** 87 uploaded:
- 85 `parsed`, 2 `failed` (`INGEST_23514`, DP-03), 0 `DOCUMENT_MISSING`, 0 DLQ
- transient codes seen while draining: `INGEST_23505` ×4, `INGEST_40P01` ×1; all succeeded within 3 attempts
- `parse_warnings`: only due-date detections, plus `No ADCB rows matched` on the card-less ADCB PDFs

**Secrets** (counts only): 7 PDF passwords and 2 mailbox refresh tokens written to Vault and verified by name.
2 app secrets found (Microsoft client id and secret). 0 skipped. 3 empty settings ignored. Fernet decryption
succeeded for every encrypted value.

**Metadata:**
- 2 profiles; owners pending until sign-up
- 0 user rules imported. All 198 legacy rules are `seed-*`, and all 198 exist in the v2 seed with the same
  pattern, match type and category.
- 2,647 category choices staged (1,648 hussain / 999 tejasvie), all `source='line'`. Legacy
  `category_overrides` is empty.
- 2,511 choices met a v2 line; 136 never will (DP-19)

**Categories.** On the 2,914 matched lines, 95.6 % agree. All 129 disagreements are improvements:
- 120 lines legacy left `Uncategorized` now have a rule category: dining 51, utilities 13, transport 11,
  grocery 10, medicine 10, donation 7, subscription 6, travel 6, shopping 5, government 1
- 9 lines carried a stale legacy typo category name

Kind fixes: 22 café purchases that legacy typed `fee` are now `purchase`, and 5 finance charges are now
`interest`.

**Recon** (78 active statements):

| Bank | ok | warn | fail | Why |
|---|---|---|---|---|
| ADCB | 21 | | | balance equation only (DP-08) |
| ENBD | 19 | | | all checks pass |
| FAB | 14 | | 6 | 2 missing rows (DP-07), 4 credit-total extraction (DP-10) |
| SIB (history) | 6 | | | no real checks for history extracts |
| MASHREQ | | 12 | | totals not extracted (DP-12) |

**Match reviews (open).** `orphaned` 150 (DP-06), `period_overlap` 8 (DP-04). Nothing `ambiguous` or
`low_score`, because no SMS evidence exists for these profiles.

**Duplicate-looking transactions in v2** (same account, date, amount, currency, direction and description):
FAB 4 groups / 13 transactions, Mashreq 4 / 8, ENBD 1 / 2. These are identical to legacy (genuine same-day
repeat purchases). v2 introduced **no** new duplicates.

**Null AED.** 0 transactions. 3 FX statement lines with a null AED (1 current) now carry an estimated AED
(`amount_aed_is_estimate`), where legacy counted them as 0.

**Uncategorised (posted):**

| | Legacy | v2 rules only | v2 + LLM |
|---|---|---|---|
| hussain | 163 / 1,836 (8.9 %) | 160 / 1,706 (9.4 %) | 39 (2.3 %) |
| tejasvie | 230 / 1,233 (18.7 %) | 110 / 1,233 (8.9 %) | 21 (1.7 %) |

## LLM categorisation (live check)

`enqueue_llm_categorize()` queued 12 batches: 134 uncategorised merchants for hussain, 92 for tejasvie, plus
demo merchants. All batches completed (`done`) with no retries or DLQ, in about 71 s in total.

| Profile | Merchants with a stored suggestion | ≥ 0.9 | 0.7–0.9 | 0.5–0.7 | Mean | Transactions now categorised by LLM |
|---|---|---|---|---|---|---|
| hussain | 101 / 134 | 45 | 43 | 13 | 0.82 | 121 |
| tejasvie | 74 / 92 | 21 | 37 | 16 | 0.78 | 89 |

51 merchants got nothing. `apply_llm_suggestions` drops confidence < 0.5, so the true distribution below 0.5 is
not observable.

Suggested categories:
- hussain: dining 32, shopping 16, grocery 15, transport 9, entertainment 9
- tejasvie: shopping 28, dining 15, grocery 10

**Quality** on a random sample of 45 suggestions: about 40 clearly correct, 5 debatable, none absurd.

Correct examples:
- UK and Kenyan supermarket chains → Grocery
- a burger chain, an Italian grill and an ice-cream parlour → Dining
- a city bus operator and a parking operator → Transport
- a government e-services portal → Fines/Govt Services
- a clinic, a pharmacy and a hospital → Medicine
- an AI-assistant subscription → Subscription
- a charity platform → Donation
- an airport duty-free shop and a fashion retailer → Shopping

Debatable examples:
- confectionery and sweet shops → Dining (Grocery is arguable)
- a corporate real-estate entity → Investment
- an in-flight catering company → Travel
- a tech-expo ticket → Entertainment (0.5)
- a temple → Donation (0.5)

The Mashreq FX merchant fragmentation (DP-11) shows up in the prompts: merchant names carry FX residue (a
reference number and the original amount), so each such merchant is categorised once and never reused.

## Recommended fix order before cutover

1. DP-03 (+DP-04): ENBD year inference in `enbd.py`, with golden tests for the Dec and Jan layouts.
2. DP-02: additive history ingestion.
3. DP-01: card-aware statement identity / no destructive replace by an empty or different-card document.
   Fix the ADCB card regex.
4. DP-05: parity report casts, plus a line-level loss check that gates the sign-off.
5. Re-run this rehearsal end to end: `delete` the two local profiles, then repeat steps 2–4. The target is FAB
   and Mashreq parity, which already holds, plus ADCB, ENBD and SIB lost lines = 0. After that, the only
   expected deltas are the ENBD phantom (−5,083 AED, correct), refund netting, DP-09 and the new SIB lines.

## Fix status

Collected 2026-10-08 from the fixes recorded in [01](01-database.md#fix-status) (database) and
[03](03-server.md#fix-status) (parser, script). Open items are in [BACKLOG.md](BACKLOG.md).

| ID | Status | Where |
|---|---|---|
| DP-01, DP-02 | fixed | `…1600`: lines carry `source_doc_codes`; only a re-parse of the same document withdraws lines; a card-less statement without rows is skipped. Re-run on the 33 hussain ADCB/SIB documents: ADCB 80.8 % → 100 %, SIB 53.2 % → 100 % |
| DP-03, DP-04 | fixed | parser `period_years.py` and contract validation: the three ENBD PDFs give Jan-2025, Jan-2026 and Dec-2025 (2025-12-28); 38 lines recovered. Ingest-side future-date guard: BACKLOG DP-04r |
| DP-05 | fixed | `legacy_parity_report(p_schema)` casts and reports `legacy_lines_missing` / `legacy_aed_missing`; `legacy_missing_lines()` |
| DP-06 | fixed | orphan reviews 150 → 0 after the re-parse |
| DP-07 | fixed | cause was the FAB original-amount format (`EUR 108,99`, `KWD 18.750`), not a second section; both statements reconcile |
| DP-08 | fixed | recon `n/a` for history extracts; `warn` for an empty statement whose header shows activity |
| DP-13 | fixed | `migrate_legacy.py --target local\|prod`, `--yes-i-mean-prod <ref>` for prod writes |
| DP-14 | fixed (docs) | X-03: Gmail OAuth client copied from Render (PRODUCTION §5.4) |
| DP-15 | fixed | X-08 per-profile advisory lock on ingest |
| DP-16 | fixed | ingest is order-independent (DP-01/02), so upload order no longer matters |
| DP-09–DP-12, DP-17–DP-22 | open | BACKLOG (DP-18 is a cutover decision) |

A full end-to-end re-run of this rehearsal with all fixes (including the ENBD and FAB parser
changes) is still to do; it is in BACKLOG "Do before / at cutover".

**Database P2/P3 pass (2026-10-09):** DP-04r fixed (ingest rejects a statement more than 31 days
ahead, `20261009000100`); DP-09 fixed (Cashback `MURABAHA PROFIT` / `BONUS` need a credit,
`…0200`); DP-19 fixed (`private.legacy_category_aliases` with `Entretainment` → `Entertainment`,
`private.legacy_unresolved_category_names()` for finalize, `…0500`); DP-21 accepted (noted in
PRODUCTION §2.6 next to the legacy-choice reports). DP-20 (card replacement opens a second
account) stays open: it needs a model decision (automatic replacement vs a "merge accounts"
action that re-points statements, lines and transactions), see BACKLOG.
