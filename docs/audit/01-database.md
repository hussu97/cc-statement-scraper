# Audit 01: Database layer (Ledger v2)

**Scope:** every file in `supabase/migrations/` (18 migrations, ~5.3k lines) and `supabase/tests/` (7 pgTAP files).
**Branch:** `ledger-v2` @ `4ec697c`. **Date:** 2026-10-08.
**Method:** I read every migration and tracked the final definition of each redefined function (Appendix A). I checked grants and ACLs in the live local catalog. I ran `supabase test db`. I ran experiments against the local stack (`127.0.0.1:54322`), each inside `BEGIN … ROLLBACK`, using throw-away users and profiles. No source files were changed.

> The local DB is not empty. It holds cutover-rehearsal data: 6 profiles, about 3.7k transactions, and a populated `legacy` schema. All experiments created their own profiles and were rolled back. The only data quoted here is aggregate counts.

## Summary

| Severity | Count |
|---|---|
| P0: must fix before cutover (security or data loss) | 2 |
| P1: fix before cutover if possible | 10 |
| P2: soon after | 16 |
| P3: nice to have | 17 |

The two P0s share one root cause, which is also DB-03. Child tables carry a `profile_code`, but nothing ties it to the parent row's profile. Some `SECURITY DEFINER` RPC branches and the matcher join on `account_code` or `stmt_code` alone. An owner of profile A can therefore bind, read and destroy profile B's ledger data if they know one of B's opaque codes. A household member who is a viewer on B can see those codes.

## Findings

| ID | Sev | Category | Location | Title |
|---|---|---|---|---|
| DB-01 | P0 | security | `…0700_ingest_and_match.sql:1117-1132` `resolve_review` (card branch); `:109` `ensure_card`; `:390-391` `match_statement_lines`; `:537` `match_sms` | `resolve_review {"card":{"account_code"}}` accepts another profile's account. The victim's statement lines then attach to the attacker's transactions. |
| DB-02 | P0 | security | `…0700:1133-1146` `resolve_review` (supersede branch) | `{"supersede": stm_…}` deactivates the evidence and lines of **any** profile's statement and orphans its transactions |
| DB-03 | P1 | data | all child tables (`cards`, `statement_lines`, `transactions`, `transaction_evidence`, `sms_messages`, `email_routes`, …) | No composite `(profile_code, parent_code)` FKs, and the matcher's candidate joins ignore `profile_code`. This is the root cause of DB-01, DB-02 and DB-14. |
| DB-04 | P1 | security | `…0500_ledger.sql:295-296`, `…0400_sms.sql:73`, `…0900:349-356`, `…1000:83-237` | Global tables are readable by any signed-up stranger: every merchant key of every profile, and SMS template examples (LLM proposals embed a user's raw SMS) |
| DB-05 | P1 | security | `…0650_seed_defaults.sql:262-277` `create_profile`; `…0950_legacy_import.sql:96-98` `import_legacy_metadata` | Profile-key squatting: a stranger who creates a profile with key `hussain` before the import co-owns the migrated ledger |
| DB-06 | P1 | bug | `…0700:704-740` `ingest_one_statement`; `:848-887` `ingest_parsed_document` | Re-parsing a document whose statement identity changed (date or account) leaves the old statement active, so transactions are duplicated |
| DB-07 | P1 | bug | `…0700:133-169` `resolve_statement_account` | `primary_card_last4 = null` with ≥2 accounts at that bank creates a **new account on every ingest**, duplicating everything |
| DB-08 | P1 | bug | `…0700:990-1037` `ingest_sms`; `…1000:57-58` `apply_sms_template` | One bad message (missing id, null body, impossible date) aborts the whole SMS batch, so the iOS outbox retries forever |
| DB-09 | P1 | bug | `…0500:119-132` `validate_rule`; `…0600:53-54` `recategorize` | `category_rules.conditions` is never validated. `{"amount_min":"100 AED"}` makes every later ingest for the profile fail, and statements go to the DLQ. |
| DB-10 | P1 | bug | `…0700:416-425` `match_statement_lines`, `:546-547` `match_sms` | The matcher flags trivially separable pairs as `ambiguous` (same amount, same day, different merchants) |
| DB-11 | P1 | bug | `…0950:235-271` `legacy_parity_report` | Fails on the real legacy schema (`varchar` vs `text`). The cutover parity sign-off (`migrate_legacy.py --step finalize`) cannot run. |
| DB-12 | P1 | bug | `…0950:195-230, 274-275` `apply_legacy_category_choices` + cron | The nightly cron re-applies already-applied legacy choices and overwrites later user edits. It never stops while any choice is unmatched. |
| DB-13 | P2 | bug/security | `…0400:161`, `…0600:20,294`, `…0700:853`, `…1300:109` | Function-level `SET statement_timeout` has no effect. The regex guard and the documented 120 s ingest budget are not applied. |
| DB-14 | P2 | security | `…0300:155-169, 206-209` `email_routes` | An owner can attach routes to another profile's mailbox (`mailbox_code` is a plain FK and is updatable) |
| DB-15 | P2 | bug | `…0700:499-516` `match_sms` step 1 | The duplicate-SMS heuristic merges genuine repeat purchases (same merchant and amount within 3 min) and ignores `available_limit` |
| DB-16 | P2 | bug | `…0700:606-611` `reconcile_statement` | Reconciliation sums only `amount_aed`. Lines with null AED (allowed by the contract, e.g. Mashreq FX rows) produce a false `fail`. |
| DB-17 | P2 | bug | `…0700:651-665`, `:280-288`, `:975-981` | `missing_from_statement` reviews never auto-resolve. `unknown_card` SMS are not re-processed when a statement registers the card. |
| DB-18 | P2 | bug | `…1300:192,205-206` `overview` | The month-to-date base window overruns into the current month on the 29th–31st |
| DB-19 | P2 | perf | `…0500:51-73` `resolve_merchant`; `…0700:381` | Every merchant lookup rewrites a global `merchants` row (19,614 updates for 843 rows locally). The lookup runs once per candidate pair. |
| DB-20 | P2 | perf | `…0800:43-46` `v_transactions` | `has_sms` / `has_statement` become hashed SubPlans that seq-scan **all** `transaction_evidence` on every page read |
| DB-21 | P2 | data | `…0900:134-151`; `…0850:374-409` | Deleting a profile leaves its Vault PDF passwords behind. In a user JWT context the delete fails on the `trg_audit` FK. |
| DB-22 | P2 | bug | `…0700:1040-1062` `trg_sms_templates_reprocess` | Re-processing always takes the oldest 500 unparsed SMS (starvation). It is global and also runs when a template is deactivated. |
| DB-23 | P2 | security | `…0950:20-38`; `…1400:23` | Pending-invite claim and `add_profile_member` trust `auth.users.email` without `email_confirmed_at` (risk depends on auth settings) |
| DB-24 | P2 | data | `…0650_seed_defaults.sql:60-63,111,148,218,229` | Short `contains` seed rules mis-categorise: `INTEREST CHARGES` → Dining (`REST`), plus `NOON`, `LIME`, `BONUS`, `HEALTH` |
| DB-25 | P2 | bug | `…0850:333-353` `nightly`; `…0900:240-275`; `…0600:197-217` | Cron jobs have no per-profile error isolation. One profile's error aborts the job for everyone. |
| DB-26 | P2 | security | `…0400:187-221`; `…0900:337-409` | Template validation gaps: a template with empty `examples` is never validated, `field_groups` shape is unchecked, and LLM proposals default to sender `.*` and go live globally |
| DB-27 | P2 | bug | `…0700:1094-1099` `resolve_review` (link) | Linking a held line to a transaction deactivates that transaction's previous line, which then belongs to no transaction (spend undercount). Code read only. |
| DB-28 | P2 | test-gap | `supabase/tests/*` | The suite fails on a non-empty DB (02, 03). There are no negative tests for cross-profile RPC arguments, the parity report is only tested against mocked `text` columns, and DB-05–DB-10 have no tests. |
| DB-29 | P3 | readability | `ARCHITECTURE.md` vs `…0850`, `…0500:262-264` | Documented but not implemented: insight kinds `spend_pace`, `new_recurring`, `review_backlog`, `large_transaction`; `amount_drift` reviews; the regex timeout |
| DB-30 | P3 | security | default ACL on `public` | `anon`/`authenticated` hold `TRUNCATE`, `TRIGGER`, `REFERENCES` and `MAINTAIN` on every table. `TRUNCATE` bypasses RLS. |
| DB-31 | P3 | bug | `…1300:97-168` `preview_rule` | `would_change` ignores the equal-priority tie-break (longer pattern wins) and counts the rule being edited |
| DB-32 | P3 | perf | various | Missing indexes (`estimate_fx`, `related_txn_code`, `rule_code`, `stmt_code`). `anomalies` is O(n²). |
| DB-33 | P3 | bug | `…0700:1133-1146` | Supersede doesn't check that the target is the same account, one of the overlap candidates, or not the subject itself |
| DB-34 | P3 | readability | `…0700:952-956, 934`; `…0200:10-11` | `declined` SMS are stored `parsed` (the docs say ignored). `Asia/Dubai` is hard-coded while `profiles.timezone` and `base_currency` are unused. |
| DB-35 | P3 | security | `…0100:55-79` `gen_code` | The UUIDv4 version nibble lowers code entropy to about 79 bits (negligible) |
| DB-36 | P3 | bug | `…0700:931-939` `process_sms` | `event_at` has no sanity bound against `received_at`. A DD/MM vs MM/DD template mistake moves transactions by months. |
| DB-37 | P3 | perf | `…0900:240-275` | `enqueue_llm_categorize` re-asks low-confidence merchants every night, indefinitely |
| DB-38 | P3 | readability | `…0900:418-445` `ops_health` | `recon_failed` and `open_reviews` are all-time counts. Combined with DB-17, the Sentry issues never clear. |
| DB-39 | P3 | bug | `…1300:251-255`, `…0800:288` | Utilisation uses the signed closing balance, so it goes negative when the card is in credit |
| DB-40 | P3 | security | `…1400:10-48` | `add_profile_member` reveals whether an email has an account (`invited` vs `added`) and adds users without consent |
| DB-41 | P3 | readability | Appendix A; `…0000:4` | 8 functions are redefined across migrations. One stale filename reference. |
| DB-42 | P3 | bug | `…0700` ingest paths | Concurrent SMS and statement ingestion on the same account can double-create (no per-account lock). Unverified. |
| DB-43 | P3 | bug | `…0700:1117-1132` | Resolving `unknown_card` for an SMS without last4 marks the review resolved but never processes the SMS. Code read only. |
| DB-44 | P3 | perf | `…0600:86-132` | Statement-level categorisation triggers fire once per single-row statement inside loops: two `recategorize` runs per new line |
| DB-45 | P3 | data | `…0800:20` `v_spend` | Pending foreign SMS with no FX rate (`amount_aed is null`) silently disappear from spend, budgets and `pending_amount` |

---

## P0

### DB-01: `resolve_review` card registration binds another profile's account (cross-tenant read and corruption)

**Location:** `20261008000700_ingest_and_match.sql:1117-1132` (`resolve_review`, branch `p_action ? 'card'`), `:109-131` (`private.ensure_card`), `:388-400` (`match_statement_lines` candidate join `t.account_code = l.account_code`), `:534-541` (`match_sms` candidate join).

**What's wrong:** The owner check runs against `r.profile_code`, the review's profile. `p_action->'card'->>'account_code'` is then passed to `ensure_card` unchecked, and `cards.account_code` is a plain FK. The new card belongs to the caller's profile but points at the victim's account. `process_sms` then gives the caller's SMS `account_code = <victim account>`, and `new_transaction_from_sms` creates a transaction with `profile_code = A` and `account_code = B's account`.

The matchers select candidates by `account_code` only. When B's next statement arrives, B's line matches A's transaction and links to it. B loses the transaction, because RLS hides profile A's row. A's transaction is then refreshed with B's line facts: description, amount and `stmt_code`.

**Experiment (E2b, rolled back):** Stranger A owns profile A. A ingests one SMS on `XXX1111` (B's real card number), which raises an `unknown_card` review in A. A calls `resolve_review(rev, {"card":{"account_code":"<B's acc>"}})`, gets `card_registered`, then plants a pending AED 55 SMS dated 20 Aug. B ingests the September statement containing `NETFLIX.COM AMSTERDAM 55.00`:

```
victim_match         {"held": 0, "linked": 1, "created": 0}
owned_by_attacker=t  status=posted  description=NETFLIX.COM AMSTERDAM  method=exact role=post
attacker sees        NETFLIX.COM AMSTERDAM | 55.00 | posted | has_victim_stmt_code=t
victim sees          aug20_txns = 0
```

**Precondition:** A must know B's `account_code`. Any member of B can read it, including a viewer, through `accounts` or `filter_meta`, and it appears in URLs and Sentry tags ("tags carry only opaque codes").

**Fix:**
1. In the card branch, require `exists (select 1 from accounts where account_code = … and profile_code = r.profile_code)`.
2. Add `l.profile_code = t.profile_code` (and `s.profile_code`) to every matcher candidate join.
3. Add composite FKs (DB-03).
4. Add pgTAP negative tests.

### DB-02: `resolve_review` supersede destroys another profile's statement

**Location:** `20261008000700_ingest_and_match.sql:1133-1146`.

**What's wrong:** Only the first `UPDATE public.statements … where stmt_code = X and profile_code = r.profile_code` is scoped to the profile. The next two statements run with `where l.stmt_code = p_action->>'supersede'` and no profile filter:
- the `transaction_evidence` deactivation
- `update statement_lines set is_current = false`

Any owner who has a `period_overlap` review can fabricate one by uploading two overlapping PDFs. They can then pass any profile's `stmt_code`.

**Experiment (E3):**

```
attacker_has_overlap_review = t ; outcome = superseded
victim: stmt status = active | current_lines = 0 | txn statuses = orphaned,orphaned | open orphan reviews = 2
```

B's statement stays `active` but now has no current lines. B's spend for that cycle drops to 0, and B gets a flood of `orphaned` reviews.

**Fix:**
- Resolve the target with `select … from statements where stmt_code = $1 and profile_code = r.profile_code and account_code = r.account_code and stmt_code <> r.subject_code`. Raise if it isn't found, and use that row's code in all three statements.
- Better, restrict the target to the `candidates` stored on the review.

---

## P1

### DB-03: Tenant integrity is by convention only

**What's wrong:** Every child table has its own `profile_code`, as ARCHITECTURE §3 says, so RLS stays a single predicate. Nothing keeps that value equal to the parent's. Examples:
- `cards.account_code`
- `statement_lines.stmt_code` / `account_code`
- `transactions.account_code`
- `transaction_evidence.txn_code` / `line_code` / `sms_code`
- `sms_messages.account_code` / `card_code`
- `email_routes.mailbox_code`

Category FKs are composite and correctly prevent cross-profile categories. The account, statement, evidence and mailbox FKs are not composite. Matching and reconciliation queries filter by `account_code` or `stmt_code` only (`match_statement_lines:390`, `match_sms:537`, `reconcile_statement:656`, `void_released_authorisations:1179`, `overview.unbilled_aed`). One mis-bound row therefore crosses tenants. DB-01, DB-02 and DB-14 are the exploitable instances.

**Fix:**
- Add `unique (profile_code, account_code)` (and the same for `stmt_code`, `txn_code`, `line_code`, `sms_code`, `mailbox_code`) on the parents.
- Change the child FKs to `foreign key (profile_code, account_code) references accounts(profile_code, account_code)`, and so on.
- At cutover the tables are fresh, so this is cheap now and expensive later.

### DB-04: Signed-up strangers can read every profile's merchants and some raw SMS

**Location:** `merchants_read` / `merchant_aliases_read` / `sms_templates_read` are `using (true)` (`…0500:295-296`, `…0400:73`). `propose_sms_template` stores the triggering message, sender and full body, as the template's example (`…0900:349-356`). The seed templates contain real card last4s, available limits and merchants (`…1000:92-235`).

**Context:** Sign-ups are open: `config.toml` has `enable_signup = true`, and PRODUCTION.md §2.2 says to "Leave email sign-ups on … RLS isolates any stray account anyway".

**Experiment (E16):** A fresh user with no membership sees `merchants_visible = 843`, `templates_visible = 33`, `llm_templates_visible = 1` (an example holding a real user's SMS body), and `transactions = 0`. Merchant keys are derived from statement descriptions, so they reveal where each household shops (pharmacies, clinics and so on).

**Fix:**
- Restrict `merchants` and `merchant_aliases` reads to merchants referenced by the caller's transactions, or move them behind an RPC.
- Strip `examples` from client reads with a column grant, or a view without `examples` for `authenticated`.
- Don't store user SMS bodies in global rows. Keep the example in a per-profile table and validate against it in the trigger.
- Disable sign-ups after invites are claimed, and fix the PRODUCTION.md wording.

### DB-05: Legacy import adopts a squatted profile key

**Location:** `create_profile(p_key, …)` lets any authenticated user pick any unused `key` (`…0650:262-277`). `import_legacy_metadata` does `insert … on conflict (key) do nothing; select profile_code … where key = r.key` (`…0950:96-98`), so it imports into whichever profile already holds the key.

**Experiment (E13):** A stranger runs `create_profile('squatme', …)`, then the import runs for legacy key `squatme`:

```
import_adopted_squatters_profile = t
members: real owner (owner), stranger (owner)
```

`scripts/migrate_legacy.py` then moves PDFs and Vault passwords into that profile. The stranger, as an owner, can read the parsed statements and the PDFs (the storage policy is per profile folder).

**Context:** The keys appear in the repo (`hussain` in PRODUCTION.md), and sign-ups are open during the window between `db push` and the import.

**Fix:**
- The import must raise if a profile with the key exists and has any member who is not in `p_member_emails`.
- Optionally reserve legacy keys in the first migration.
- Or don't let `create_profile` callers choose `key` at all: derive it, or make it nullable for non-legacy profiles.

### DB-06: Re-parsing a document with a corrected statement date or account duplicates the ledger

**Location:** `ingest_one_statement` finds the statement by `(account, statement_date, kind)` only (`…0700:704-706`). `ingest_parsed_document` never retires statements that this `doc_code` produced before but that are missing from the new payload. `line_key` also includes `v_account` (`:759`).

**Experiment (E17):** I ingested a 6-line statement dated 2026-07-31, then re-ran `ingest_parsed_document` on the **same doc** with `statement_date = 2026-08-01`, as after a parser date fix:

```
2026-07-31 active 6 current lines | 2026-08-01 active 2 current lines
STARBUCKS transactions for 2 real coffees = 4 ; spend 72.00 (should be 36.00)
```

**Fix:** In `ingest_parsed_document`, after the loop, supersede the statements with `doc_code = p_doc_code` that weren't touched in this run. Deactivate their lines and evidence and refresh the affected transactions, the same way the `_gone` path does, so the re-parse can re-attach the transactions. Add a test.

### DB-07: A missing primary card last4 creates a new account on every ingest

**Location:** `resolve_statement_account` (`…0700:144-158`). When `p_last4` is null and the bank has ≠1 active accounts, `v_account` stays null and a fresh account is inserted. The parser emits `primary_card_last4: null` for the legacy `0000` sentinel (`services/parser/README.md`, `test_unknown_card_sentinel_becomes_null`).

**Experiment (E12):** The profile has two ADCB accounts. I ingested the same null-last4 payload twice:

```
first_account  acc_…61m ; second_account acc_…9t6 ; accounts = 4 ; SHOP txns = 2
```

**Fix:** With a null last4 and an ambiguous account, raise a permanent error or open an `unknown_card`-style review. Never insert. At minimum, reuse an existing statement with the same `doc_code` or the same `statement_reference`.

### DB-08: One bad SMS fails the whole batch

**Location:** `ingest_sms` (`…0700:1007-1034`) has no per-message `BEGIN … EXCEPTION`. The final `apply_sms_template` calls `to_date` unguarded (`…1000:57-58`).

**Experiments (E10, E10b):**
- One message without `client_msg_id` next to a good one: `ERROR: null value in column "client_msg_id"`. The good message is lost too.
- A FAB-format SMS with date `31/02/26`: `ERROR: date/time field value out of range` from `apply_sms_template`, raised through `match_sms_template` → `process_sms` → `ingest_sms`.

The iOS outbox retries a failed batch with backoff indefinitely, so the poison message blocks every later message in that batch. The same happens for any error raised under `process_sms`, such as DB-09 and DB-26.

**Fix:**
- Validate the input shape per message: return `{"status":"rejected","reason":…}` for a missing or invalid `client_msg_id`, body or `received_at`.
- Wrap `process_sms` in a sub-block with an exception handler that stores `parse_status = 'failed'` and the error code.
- Guard `to_date` inside `apply_sms_template`. A non-matching date should mean "template does not apply", not an exception.

### DB-09: Unvalidated rule conditions turn into an ingestion outage

**Location:** `validate_rule` only compiles regex patterns (`…0500:119-132`). `recategorize` casts `conditions->>'amount_min'` to numeric at run time (`…0600:53-54`). `category_rules` is directly writable by owners through PostgREST.

**Experiment (E9):** I inserted a rule `contains 'ZZQQ'` with `{"amount_min":"100 AED"}`. The insert succeeded because no transaction matched yet. The next statement containing a `ZZQQ SHOP` line failed:

```
ERROR: invalid input syntax for type numeric: "100 AED"
… private.recategorize … trg_transactions_categorize_new … new_transaction_from_line … ingest_parsed_document
```

Every re-parse of that document fails the same way, so it ends up in the DLQ after 5 reads. Any SMS that matches the rule fails its batch (DB-08).

**Fix:**
- Add a CHECK or trigger that validates `conditions`: only allow known keys, numeric `amount_min`/`amount_max`, a valid direction or kind, and `card_code`/`bank_code` values that exist and are the profile's own.
- Make the casts defensive with a safe numeric helper that returns null.

### DB-10: The matcher calls separable candidates ambiguous

**Location:** The conflict test is "any materially different competitor within 15 points" (`…0700:416-425`, `:546-547`). A same-day, same-amount candidate at a **different merchant** scores 50 + 25 + (15 × trigram similarity) + 10 = 85 to 89. The correct pair scores 100. That is within 15, so it's a conflict, even though the competitor is clearly worse on the only distinguishing component.

**Experiment (E6):**
- SMS: AED 100 at ENOC, 09:00. SMS: AED 100 at Carrefour, 19:00.
- Statement lines: `ENOC STATION 1021 DUBAI 100` and `CARREFOUR MOE DUBAI 100`.
- Result: `{"held": 2, "linked": 1, "created": 3}`, open reviews `ambiguous 2`, `missing_from_statement 2`.

The user gets 4 reviews for an obvious pairing. After they link both, the 2 `missing_from_statement` reviews stay open (DB-17).

Synthetic stress test (E8): matching a 250-line statement against its own 250-line SIB history extract held **200 of 250** lines, because same-amount, same-date rows with similar merchant names conflict. Real data is less adversarial: the rehearsal DB has 1 open `ambiguous` review.

**Fix:** Use mutual-best matching. Auto-link when the pair is the top candidate for both its line and its transaction, by a small margin (for example ≥ 5 points), or when the competitor loses on merchant similarity by ≥ 0.3. Keep the 15-point rule only when the merchant components are close.

### DB-11: The legacy parity report crashes on the real legacy schema

**Location:** `private.legacy_parity_report()` (`…0950:235-271`) declares `returns table (profile_key text, bank_code text, …)`, but `legacy.profiles.key` is `varchar(64)`.

**Experiment:** `select … from private.legacy_parity_report()` against the local rehearsal legacy schema:

```
ERROR: structure of query does not match function result type
DETAIL: Returned type character varying does not match expected type text in column 1.
```

`03_legacy_import.test.sql` mocks the legacy tables with `text` columns, so CI passes. PRODUCTION.md step "Parity sign-off" (`migrate_legacy.py --step finalize`, line 483) cannot run.

**Fix:** Cast `p.key::text, s.bank_code::text`, and check every column against `\d legacy.*`. Have the test create the mock tables with the real legacy types (`varchar`, enums).

### DB-12: The legacy-choices cron re-applies choices forever and overrides user edits

**Location:** The cron condition is "any choice with `applied_at is null`" (`…0950:274-275`). The `choice` CTE does **not** filter `applied_at` (`:204-215`). Any choice whose fingerprint never meets a line keeps the job running every night, and each run re-applies **all** choices to transactions whose `manual_category_code` is null. `set_transaction_category(…, p_apply_to_merchant => true)` nulls `manual_category_code` by design (`…0600:252`).

**Experiment (E6-legacy):** I staged an override for `JOES DINER` (Travel) and one unmatched fingerprint, then ran the import.

| Step | Effective category |
|---|---|
| After import | Travel |
| User applies Dining to the merchant | Dining |
| Next nightly run (`applied_2 = 1`) | Travel |

In the rehearsal DB, **36** staged choices never match a line, so the job would never stop.

**Fix:**
- Apply only `where ch.applied_at is null`.
- Set `applied_at` on the rows actually applied.
- Unschedule the job after N days, or once `count(unapplied)` stops changing.

---

## P2

### DB-13: Function-level `SET statement_timeout` is a no-op

**Location:**
- `match_sms_template` sets 2 s, documented as "guard against pathological regex" (`…0400:161`)
- `recategorize` sets 30 s (`…0600:20`)
- `preview_rule` sets 10 s (`…0600:294`, `…1300:109`)
- `ingest_parsed_document` sets 120 s (`…0700:853`); ARCHITECTURE §4 says "with a 120 s statement timeout"

**Experiment (E1):** A function with `set statement_timeout='1s'` that sleeps 2.5 s finished normally in **2511 ms**. Postgres arms the timer at statement start, so a GUC change inside the call doesn't affect the running statement.

**Consequence:**
- Regex cost is bounded only by the caller's role timeout: `authenticated` 8 s, `service_role` none, pg_cron none.
- The worker calls `ingest_parsed_document` through PostgREST (`worker/parse_document.ts:153`). It therefore probably runs under the `authenticator` session's `statement_timeout = 8s` (`service_role` has no override), not 120 s. I did not verify this end to end. E8 measured about 1 s for a 250-line statement, so this is headroom, not a current failure.

**Fix:**
- Set `statement_timeout` on the role: `alter role service_role set statement_timeout = '120s'`. Or call `set_config('statement_timeout', …)` before the outer statement, from the Edge Function with `SET` via a pg connection.
- Bound regex work instead: cap the pattern length and reject backreferences.
- Remove the misleading attributes and the ARCHITECTURE sentence.

### DB-14: Email routes can target another profile's mailbox

**Location:** `email_routes.mailbox_code` is a simple FK. Owners have `INSERT` and `UPDATE (mailbox_code, …)`. The RLS `with check` only constrains `profile_code` (`…0300:155-169, 198-209`).

**Experiment (E4):** The owner of A inserted `email_routes(profile_code=A, mailbox_code=<B's mailbox>, bank_code='FAB', sender_allowlist={'*'})` → `INSERT 0 1`.

**Impact:** `mailboxRoutes()` (`_shared/email_ingest.ts:33`) loads routes by `mailbox_code` only, so A's route widens what gets ingested from B's inbox. Documents still land in the mailbox owner's profile (`email_ingest.ts:90`), so A cannot read them. This is an integrity issue, not a read.

**Fix:** Composite FK `(profile_code, mailbox_code)` (DB-03).

### DB-15: The duplicate-SMS heuristic merges real repeat purchases

**Location:** `match_sms` step 1 (`…0700:500-516`): same account, kind, amount and currency, and (the same body hash, or Δevent ≤ 180 s and description similarity ≥ 0.8), received within 10 min.

**Experiment (E5):** Two AED 18 coffees at the same merchant, 2 minutes apart, with available limits 5000.00 and 4982.00. Result: `first = created`, `second = duplicate`. Pending spend undercounts until the statement posts.

**Fix:** Treat differing `available_limit`, or differing printed times when the template has a time group, as proof that the alerts are distinct. Keep the body-hash rule.

### DB-16: Reconciliation ignores lines without an AED amount

**Location:** `reconcile_statement` (`…0700:606-611`) sums `amount_aed` only. Contract parse-v1 says "`amount_aed` is null when the bank does not print the AED amount (e.g. Mashreq foreign rows)". `statement_cycles` (`…0800:290-293`) has the same flaw.

**Experiment (E8-recon):** A statement with one EUR row with null `amount_aed`, and correct totals: `status = fail`, `sum_debits = 248.50`, `debits_match = false`, `balance_equation = false`.

**Fix:** Sum `coalesce(amount_aed, round(amount_original * fx_rate, 2))`, or report "unknown AED amount" lines separately and downgrade to `warn` when the mismatch equals their estimate.

### DB-17: Stale reviews

**Location:**
- `missing_from_statement` reviews (`…0700:651-665`) are never closed. `refresh_transaction` auto-resolves only `orphaned` reviews (`:284-288`).
- An SMS held as `unknown_card` is only re-processed through `resolve_review`. A later statement that registers the same card (`ensure_card` in `ingest_one_statement`) does not trigger it.

**Experiment (E10):** After the user linked both ambiguous lines from DB-10, the transactions were `posted 3`, but `missing_from_statement` was still `open 2`.

**Impact:** The review inbox and `ops_health.open_reviews` only ever grow.

**Fix:**
- In `refresh_transaction`, resolve open `missing_from_statement` reviews for the transaction when its status ≠ `pending`.
- After `ensure_card` inserts a card, re-process `sms_messages` where `account_code is null and bank_code = … and card_last4 = …`, and auto-resolve their reviews.

### DB-18: The overview's month-to-date base includes days of the current month

**Location:** `overview` (`…1300:192, 205-206`): `v_day` is capped at the length of the **viewed** month, and the window is `txn_date < v_prev + v_day`.

**Experiment (E11, arithmetic):**

| Today | Window end (exclusive) | Overrun |
|---|---|---|
| 2027-03-30 | 2027-03-03 | 1–2 March counted as "February MTD" |
| 2026-12-31 | 2026-12-02 | 1 December |

`change_vs_prev_month_to_date` is wrong on the 29th–31st after a shorter month.

**Fix:** `least(v_prev + v_day, v_month)`.

### DB-19: `resolve_merchant` writes on every read

**Location:** `merchant_aliases` is never inserted anywhere, so every call falls through to `insert … on conflict (merchant_key) do update set merchant_key = excluded.merchant_key` (`…0500:63-71`). That writes a new tuple and takes a row lock on a **global** table. `match_statement_lines` calls it per (line, transaction) candidate pair inside the candidate SELECT (`…0700:381`).

**Evidence:** `pg_stat_user_tables` shows `merchants` with 843 live rows and **19,614 updates** (18,410 HOT). In E8, 250 lines × about 60 candidates means about 15k upserts per ingest.

**Fix:**
- Use a `select` first, then `insert … on conflict do nothing` plus a re-select.
- Resolve each line's merchant once, into `_m_lines`, and give `statement_lines` a `merchant_code` column.
- Populate or drop `merchant_aliases`.

### DB-20: The Activity read model scans all evidence

**Location:** `v_transactions.has_sms` / `has_statement` (`…0800:43-46`).

**Experiment (E9 perf, demo profile, 50-row page):**

```
SubPlan 4 -> Seq Scan on transaction_evidence e   (rows=252, 3.3 ms)
SubPlan 8 -> Seq Scan on transaction_evidence e_1 (rows=466, 1.7 ms)
```

The planner hashes the whole RLS-filtered evidence table instead of probing `transaction_evidence_txn_idx`. The cost grows with total evidence across profiles, not with page size. It is about 8 ms today.

**Fix:** Use a `LATERAL (select bool_or(...) … where e.txn_code = t.txn_code and e.is_active)` aggregate over the indexed column, or maintain `has_sms` / `has_statement` columns in `refresh_transaction`.

### DB-21: Profile deletion

**Location:**
- Vault secrets are keyed by name (`profile:<code>:<KEY>`, `mailbox:<code>:…`) and are not cascaded.
- `trg_audit` (`…0850:374-409`) inserts `audit_events` rows during the cascade delete of `category_rules` and `budgets` whenever `auth.uid()` is set.

**Experiment (E-delete):**
- As service: `DELETE 1`, with `vault_secrets_left_after_delete = 1` (the ADCB PDF password survives).
- With user claims set: `ERROR: insert or update on table "audit_events" violates foreign key constraint`.

Storage objects are also left behind; that is outside the DB.

**Fix:** Add a `delete_profile` routine (service or owner) that purges `vault.secrets where name like 'profile:'||code||':%'` and mailbox secrets and enqueues storage cleanup. Make `trg_audit` skip when the profile row is gone.

### DB-22: Template re-processing starves

**Location:** `trg_sms_templates_reprocess` (`…0700:1040-1062`) processes `parse_status in ('unparsed','pending','failed') order by received_at limit 500` across **all** profiles, synchronously, on any insert or update. That includes `set_sms_template_active(false)`, `updated_at` touches and LLM proposals.

**Impact:**
- Once 500 permanently unparsable messages exist, newer unparsed messages are never re-tried.
- Every activation runs up to 500 × N template regexes inside the owner's 8 s request.

**Fix:**
- Re-process only messages whose sender matches the template's bank senders.
- Order newest first or page with a cursor.
- Skip when only `active = false` or non-pattern columns changed.
- Move the work to the queue.

### DB-23: Invites are claimed by unconfirmed emails

**Location:** `attach_pending_members` fires **after insert on `auth.users`** (`…0950:20-38`). `add_profile_member` looks up `auth.users` by email (`…1400:23`). Neither checks `email_confirmed_at`.

**Risk:** If production ever allows password sign-ups with "Confirm email" off (local `config.toml` has `enable_confirmations = false`), anyone can register an invitee's address and inherit the invite. With email OTP or magic link only, the risk is low. This is unverified against production settings.

**Fix:** Attach on `after update of email_confirmed_at` when it becomes non-null, as well as on insert when it is already confirmed. Do the same check in `add_profile_member`.

### DB-24: Seed rules are too broad

**Location:** `…0650_seed_defaults.sql`:
- `('Dining','REST')` at :61 matches `INTEREST`, `FOREST`, `RESTORATION`
- `CAFE` / `FOOD` at :60, :63
- `('Shopping','NOON')` at :111 matches `AFTERNOON`
- `LIME` at :148 matches `SUBLIME`
- `HEALTH` at :218
- `('Cashback','BONUS')` (income, so excluded from spend) at :229

**Experiment (E8):** The line `INTEREST CHARGES` (kind interest) got category **Dining**. These rules were ported from legacy and legacy behaved the same, but v2 now matches on the full description.

**Fix:** Convert short patterns to `regex` with `\m…\M` word boundaries, or to `prefix`. Add a seed regression test with known descriptions.

### DB-25: Batch jobs fail as a whole

**Location:** `private.nightly` (`…0850:333-353`), `enqueue_llm_categorize` (`…0900:252-272`), `recategorize_stale` (`…0600:197-217`), `reestimate_pending_fx` (`…1200:51-70`) loop over profiles or transactions without `BEGIN … EXCEPTION`.

**Impact:** One bad row anywhere (for example a DB-09 rule, which makes `recategorize` raise) aborts the job for every profile. Combined with DB-38, the only signal is a cron failure.

**Fix:** Use a per-profile sub-block with an exception handler that logs to a `job_errors` table or `raise warning`, then continue.

### DB-26: SMS template safety

**Location:** `validate_sms_template` (`…0400:187-221`) validates only the provided examples. `examples` defaults to `'[]'`, so a template with no examples is never exercised. `field_groups` values are cast `value::int` at apply time, so `{"amount":"x"}` raises on every SMS that reaches that template, globally (see DB-08).

`propose_sms_template` defaults `sender_pattern` to `'.*'` (`…0900:352`). `set_sms_template_active(true)` makes it live for **every** profile, and at priority 200 it runs before the 900+ ignore templates. Any owner of the proposing profile can approve it.

**Fix:**
- Add a CHECK that `jsonb_array_length(examples) >= 1`.
- Add a CHECK that every `field_groups` value is a positive integer and every key is known.
- Require `sender_pattern` to match one of `banks.sms_senders` for `bank_code`.
- Scope LLM templates to the proposing profile until an admin promotes them.

### DB-27: Linking a held line can drop another line from the ledger (code read only)

**Location:** `resolve_review` link branch (`…0700:1094-1099`). It deactivates the target transaction's existing unlocked evidence of the same type and links the held line. The displaced line now has no active evidence and no review, and nothing re-matches it or creates a transaction for it, so its amount drops out of spend.

**Fix:** After deactivating, call `new_transaction_from_line` for each displaced line, or refuse the link when the target already has an active line.

### DB-28: Test gaps

- **Not hermetic.** `supabase test db` against the shared local DB results in `02_ledger` failing at line 143 ("more than one row returned by a subquery": `where description like 'CARREFOUR%'` has no profile filter) and `03_legacy_import` failing at line 7 (`create table legacy.profiles` collides with a real legacy schema). Scope every lookup by the test's profile and create the mocks in a test-only schema.
- **No negative tests for cross-profile arguments** to `resolve_review` (`link`, `card`, `supersede`), `set_transactions_category`, `email_routes` or `merchant_profile_category`. These would have caught DB-01, DB-02 and DB-14.
- **The parity report is tested against `text` mocks** (DB-11).
- **No tests for:**
  - null primary last4 (DB-07)
  - re-parse with a changed identity (DB-06)
  - invalid rule conditions (DB-09)
  - a poison SMS in a batch (DB-08)
  - same-amount different-merchant matching (DB-10)
  - stranger visibility of global tables (DB-04)
  - stale reviews (DB-17)
- The "identical coffee" test uses an identical `Avl Cr. limit is AED 1.00` in both bodies, which hides DB-15.

---

## P3

- **DB-29: Documentation drift.** ARCHITECTURE §6 lists insight kinds `spend_pace`, `new_recurring`, `review_backlog` and `large_transaction`. `generate_insights` (`…0850:237-331`) never emits them; the CHECK merely allows them. `amount_drift` is an allowed review reason that is never produced. §4's "regex runs under a statement timeout" is false (DB-13). PRODUCTION.md's "RLS isolates any stray account" is false (DB-04).
- **DB-30: Excess default grants.** The default ACL gives `anon`/`authenticated` the privileges `Dxtm` (TRUNCATE, REFERENCES, TRIGGER, MAINTAIN) on all `public` tables, and `TRUNCATE` ignores RLS. PostgREST and GraphQL cannot issue it, so this is defence in depth only. Fix: `revoke truncate, trigger, references, maintain on all tables in schema public from anon, authenticated` and alter the default privileges.
- **DB-31: `preview_rule` parity.** It counts a transaction as changing when `cur_priority >= p_priority`. On equal priority, `recategorize` keeps the existing rule if its pattern is longer, or same length with a better match type. When previewing an edit, the rule being edited is counted against itself. Mirror the full ORDER BY, and accept `p_rule_code` to exclude it.
- **DB-32: Indexes.**
  - `estimate_fx` scans `statement_lines` by `(profile_code, currency_original, txn_date desc)` without an index. It is called per pending transaction in `reestimate_pending_fx` and per SMS.
  - `transactions.related_txn_code` has no index (`match_sms:574` `NOT EXISTS`, plus the FK `on delete set null`).
  - `transactions.rule_code` and `transactions.stmt_code` have no index (FK `set null` scans).
  - `anomalies` runs two LATERAL aggregates per row, which is O(n²): 103 ms for 498 transactions.
- **DB-33: Supersede target validation.** Beyond DB-02, supersede accepts a statement on a different account, one outside the overlap candidates, or the subject statement itself.
- **DB-34: Inconsistent SMS handling and unused columns.**
  - `declined` SMS get `parse_status = 'parsed'` with `ignore_reason = 'declined'`; the docs say ignored.
  - `process_sms` hard-codes `Asia/Dubai` (`:934-935`), while `profiles.timezone` and `base_currency` exist, are editable (`base_currency`), and are unused.
- **DB-35: `gen_code` entropy.** The UUIDv4 version and variant bits reduce byte 6 to 16 values, giving about 79 random bits instead of 80. This is negligible.
- **DB-36: No sanity check on SMS dates.** A template date more than 7 days from `received_at` should fall back to `received_at` and log a warning. A DD/MM template applied to MM/DD text currently moves transactions by months.
- **DB-37: Repeated LLM calls.** Merchants the LLM declines (confidence < 0.5) produce no `merchant_profile_category` row, so they are re-enqueued every night. Store a "declined" marker with `category_set_hash`.
- **DB-38: `ops_health` counts are all-time.** `recon_failed` is never windowed; the rehearsal DB already has 7, so the issue would be raised forever. `open_reviews` includes the stale reviews from DB-17.
- **DB-39: Negative utilisation.** `closing_balance / limit` is negative when the card is in credit. Use `greatest(closing_balance, 0)`.
- **DB-40: `add_profile_member` behaviour.** Its result reveals whether an email is registered (`invited` vs `added`), and it attaches an existing user without their consent.
- **DB-41: Redefinitions and a stale reference.** Eight functions are redefined across migrations (Appendix A); readers must know which is final. `…0000:4` references `20261008000900_legacy_import.sql`, but the file is `…0950`. Consider squashing before the first production push, since nothing is deployed yet.
- **DB-42: Concurrent ingestion (unverified).** An SMS and a statement ingested concurrently for the same account (READ COMMITTED, no `pg_advisory_xact_lock(hashtext(account_code))`) can each create their own transaction, producing a pending duplicate until a review.
- **DB-43: `unknown_card` without last4 (code read only).** When an `unknown_card` SMS has no last4, the card branch registers nothing (`ensure_card` returns null on a null last4). The `process_sms` loop matches nothing (`card_last4 = null`), yet the review is marked `resolved`.
- **DB-44: Per-row trigger overhead.** `new_transaction_from_line` and `refresh_transaction` issue single-row INSERTs and UPDATEs in loops. Each fires a statement-level trigger that builds transition tables, and new lines are recategorised twice: once on insert, and again when `merchant_code` is set. Batch the inserts in `match_statement_lines`, or call `recategorize` once per ingest.
- **DB-45: Unestimated pending SMS vanish from spend.** `v_spend` requires `amount_aed is not null`, so pending SMS in a currency with no rate don't show in spend, budgets or `overview.pending_amount`. Surface a count of "unpriced pending" in `overview`.

---

## What was checked and found sound

- **Service guards.** Every `public` SECURITY DEFINER function granted only to `service_role` starts with `assert_service_role()`:
  - `ingest_parsed_document`, `fail_document`
  - `queue_*`
  - `worker_*`
  - `apply_llm_suggestions`, `propose_sms_template`
  - `ops_health`, `upsert_fx_rates`
  - `authenticate_service_token`

  Every user RPC calls `assert_member` and requires an owner for writes. Viewers cannot write: they can read, `preview_rule` and `list_profile_secrets` (keys only). `anon` reaches nothing.
- **RLS coverage.** RLS is on every `public` table and every table has a policy (guarded by `01_rls`). Views are `security_invoker`. SECURITY DEFINER functions pin `search_path`. Category FKs are composite, so `set_transaction_category` and `budgets` cannot cross profiles.
- **SQL injection.** Dynamic SQL exists only in the quarantine migration (`format('%I')`) and the legacy import (static text plus `USING`). There is no injection surface.
- **Vault.** Clients can set and list secret keys but cannot read values. Only service-guarded functions read `decrypted_secrets`.
- **Storage and Realtime.** The storage bucket allows member reads by profile folder; writes are service only. Realtime publication rows are RLS-filtered.
- **Reconciliation sign convention.** Opening and closing balances are signed (positive means owed); the contract and ARCHITECTURE agree. The checks use `opening + Σdebits − Σcredits = closing` with absolute line amounts and the absolute `total_debits` / `total_credits`. This is correct, apart from DB-16.
- **SMS timezone.** A printed date and time are interpreted in `Asia/Dubai`, and `txn_date = dubai_date(event_at)`. E13 shows an ENBD SMS received at 20:30Z on 31 Jul getting `txn_date` 1 Aug (Dubai). The statement line dated 31 Jul still matched within ±1 day, and the statement date wins after posting.
- **Refunds, late SMS and FX.**
  - A refund SMS links to the refund line.
  - A late SMS links as `auth` to an already-posted line (E13).
  - A pending FX SMS is replaced by the statement's AED amount, and estimates follow statement rate, then the USD peg, then `fx_rates` (existing tests 02 and 05).
- **Invalid regex and category deletion.**
  - An invalid rule regex is rejected at insert by `validate_rule`.
  - Categories cannot be deleted by clients: there is no DELETE grant or policy, and they are archived instead.
  - A service-side delete of a category used by budgets fails on the `NO ACTION` FK, which is the intended behaviour.
- **Legacy heuristic.** The "line" heuristic in `apply_legacy_category_choices` would pin only **22 of 2,561** rehearsal transactions as manual (11 that v2 leaves uncategorised, 11 where a v2 rule disagrees), which is acceptable.
- **Ingest performance.** A 250-line statement takes about 1 s and a no-op re-ingest 15 ms. `overview` takes 78 ms for a 498-transaction profile.

## Appendix A: Final definition of redefined functions

| Function | Defined in | Final |
|---|---|---|
| `public.add_profile_member` | `0650:283`, `0950:42` (drop + create, now returns text), `1400:10` | `1400` (adds the last-owner demotion guard) |
| `public.spend_series` | `0800:138`, `1300:285` (dropped, `p_top` added) | `1300` |
| `public.category_breakdown` | `0800:175`, `1400:56` (dropped, `change` added) | `1400` |
| `public.preview_rule` | `0600:282`, `1300:97` | `1300` (card_code and currency conditions, counts over every match) |
| `public.overview` | `0800:57`, `1300:180` | `1300` (still has DB-18) |
| `private.estimate_fx` | `0700:94`, `1200:34` | `1200` (adds the `fx_rates` fallback) |
| `private.bump_and_recategorize` | `0600:135`, `1100:4` | `1100` (skips deleted profiles) |
| `private.apply_sms_template` | `0400:108`, `1000:23` | `1000` (amount only required for transaction kinds) |

**Update 2026-10-09 (P2/P3 pass).** Migrations `20261009000100`–`…0500` (short names `9-100` …
`9-500` below) redefine these again; the final definitions are:

| Function | Final | Note |
|---|---|---|
| `public.overview`, `public.statement_cycles` | `9-100` | DB-18, DB-39, DB-45 |
| `public.v_transactions` (view) | `9-100` | DB-20 |
| `public.ingest_parsed_document`, `private.ingest_one_statement`, `private.refresh_transaction` | `9-100` | DP-04r, DB-17r, X-33 |
| `private.resolve_merchant`, `private.new_transaction_from_line`, `private.new_transaction_from_sms` | `9-100` | DB-19r, DB-44 |
| `public.anomalies` | `9-100` | DB-32r |
| `private.process_sms` | `9-300` (first redefined in `9-100`) | DB-34, DB-36, DB-26r scope |
| `private.seed_profile_defaults`, `private.nightly`, `private.recategorize_stale`, `private.reestimate_pending_fx`, `private.enqueue_llm_categorize`, `private.generate_insights` | `9-200` | DB-24, DB-25, DB-29r, DB-37 |
| `public.apply_llm_suggestions`, `public.preview_rule` | `9-200` (dropped, a defaulted parameter added) | DB-37, DB-31 |
| `private.match_sms_template` | `9-300` (dropped, `p_profile_code` added) | DB-26r |
| `public.propose_sms_template`, `private.trg_sms_templates_reprocess` | `9-300` | DB-26r, DB-22 |
| `public.ops_health`, `public.fail_document` | `9-400` | SRV-10, DB-38, SRV-22, SRV-20 |
| `private.trg_audit`, `private.attach_pending_members`, `public.add_profile_member`, `private.apply_legacy_category_choices` | `9-500` | DB-21, DB-23, DP-19 |

DB-41 is closed by decision: every `20261008*` migration is in production, so nothing is squashed
and the stale file name in `…0000:4` stays (PRODUCTION §2.3 notes it).

## Appendix B: Experiments

The scripts are in the session scratchpad (not committed). Each one runs `\i setup.sql` (two throw-away users and profiles plus helpers modelled on `02_ledger.test.sql`) inside `BEGIN … ROLLBACK`. To reproduce, start from `supabase/tests/02_ledger.test.sql`'s helpers and add the following:

| ID | Steps | Outcome |
|---|---|---|
| E1 | `create function … set statement_timeout='1s' … pg_sleep(2.5)` | Returns after 2511 ms |
| E2b | B ingests a statement on card 1111. A ingests an SMS on `XXX1111` (`unknown_card`), resolves with B's `account_code`, then sends an SMS for AED 55. B ingests a statement with a 55.00 line. | B's line is linked to A's transaction |
| E3 | A ingests two overlapping statements (`period_overlap` review), then `resolve_review(rev, {"supersede": <B stm>})` | B's lines are not current, and B's transactions are orphaned |
| E4 | As A, `insert into email_routes(profile_code=A, mailbox_code=<B mbx>)` | Succeeds |
| E9 | As A, insert a rule with `{"amount_min":"100 AED"}`, then ingest a matching line | Ingest raises |
| E10 / E10b | `ingest_sms` batch with a message missing `client_msg_id`; a FAB body with date `31/02/26` | Whole batch raises |
| E5 / E6 / E8 | Same-merchant coffees 2 min apart; ENOC/Carrefour AED 100 same day; EUR line with null AED; `INTEREST CHARGES` | duplicate; 2 ambiguous; recon fail; Dining |
| E17 | `ingest_parsed_document(same doc, statement_date + 1)` | 2 active statements, doubled spend |
| E12 | Two ADCB accounts, null primary last4 ingested twice | 2 new accounts |
| E6-legacy | Staged override, then apply-to-merchant, then cron | Category reverts |
| E13 | Stranger `create_profile('squatme')`, then `import_legacy_metadata` | Adopted |
| E16 | Fresh user | Counts of global tables visible |

## Fix status

Fixed on `ledger-v2` (uncommitted) by migrations `20261008001500_audit_tenant_integrity.sql`,
`…1600_audit_ingest_and_review.sql`, `…1700_audit_rule_conditions.sql`,
`…1800_audit_visibility_and_legacy.sql`, `…1900_web_review_and_search.sql`, plus `supabase/config.toml`.
Tests: `supabase/tests/08_tenant_isolation`, `09_ingest_robustness`, `10_web_review_and_search` (new),
`02_ledger` and `03_legacy_import` (made hermetic). `supabase test db` passes (10 files, 503 tests) on the
shared non-empty DB, and on a fresh throw-away stack (migrations + seed from scratch).

| ID | Status | Where (migration / test) |
|---|---|---|
| DB-01 | fixed | `…1600` `resolve_review` card branch (account must be the review's profile and bank); matcher joins on `(profile_code, account_code)`; `08` E2b negative test |
| DB-02 | fixed | `…1600` supersede target must be an open candidate of the review, same profile/account, not the subject; `08` E3 negative test |
| DB-03 | fixed | `…1500` `UNIQUE (profile_code, code)` on parents + composite FKs on every child (cards, statements, lines, SMS, transactions incl. related/rule/recurring, evidence, reviews, recon, email); old single-column FKs dropped; `08` structural tests |
| DB-04 | fixed | `…1800` merchants/aliases readable only when referenced by the caller's profiles; templates only for the caller's banks / messages / proposals; `examples` column not granted to `authenticated`; `config.toml [auth] enable_signup = false`; `08` stranger tests. **Prod:** turn off "Allow new users to sign up" in the dashboard (PRODUCTION.md §2.2 wording still needs updating) |
| DB-05 | fixed | `…1800` `private.legacy_import_profiles` provenance; import raises 23505 on a key it did not create (backfilled for the rehearsal's imported profiles); `03` squat test |
| DB-06 | fixed | `…1600` `ingest_parsed_document` phase 2 withdraws the document's evidence from statements it no longer produces; a retired statement is revived with its codes when the same document produces it again; `09` E17 test |
| DB-07 | fixed | `…1600` `resolve_statement_account`: same document → its account; one active account; explicit reference seen on exactly one account; else permanent 22023 (no account created). A card-less statement without rows is skipped with a document warning; `09` E12 + idempotency tests |
| DB-08 | fixed | `…1600` `ingest_sms` validates each message (`invalid` + `reason`) and isolates processing errors (`failed`, `ignore_reason = error:<sqlstate>`); `apply_sms_template` treats an impossible date as no match; template reprocess trigger isolates errors too; `09` tests |
| DB-09 | fixed | `…1700` `private.rule_problem` validates keys/types/ownership (trigger + `preview_rule`, 22023); `recategorize`/`preview_rule` use `private.safe_numeric`; `09` tests |
| DB-10 | fixed | `…1600` a competitor ≥ 0.3 below the pair on merchant affinity (`similarity`/`word_similarity`) is not a conflict; `09` ENOC/Carrefour test; coffee-tie test in `02` still passes |
| DB-11 / X-02 / DP-05 | fixed | `…1800` `legacy_parity_report(p_schema)` casts varchar/enum columns and adds `legacy_lines_missing` / `legacy_aed_missing`; `legacy_missing_lines()` lists lost lines; `03` uses a varchar/enum mock schema |
| DB-12 | fixed | `…1800` `private.legacy_choice_applications`: each transaction evaluated once (applied / agreed / kept_manual), never re-applied after a user edit; `legacy_choices_cron()` unschedules itself when nothing is pending or 30 days after staging; `legacy_unmatched_choices()` reports leftovers; `03` tests |
| DB-13 | fixed | `…1600`/`…1700` all function-level `statement_timeout` removed (guard in `09`); regex bounded on write (rule pattern ≤ 200, template ≤ 1000/200 chars, no back-references) and SMS bodies ≤ 2000 chars. ARCHITECTURE §4 "120 s statement timeout" sentence still needs removing |
| DB-14 | fixed | `…1500` composite FK `email_routes(profile_code, mailbox_code)`; `08` E4 test |
| DB-15 | fixed | `…1600` differing available limits are never a duplicate; `09` E5 test |
| DB-16 | fixed | `…1600` recon counts null-AED lines at their printed rate and downgrades an explained mismatch to `warn` (`unpriced_lines`); `09` test |
| DB-17 | partly fixed | `…1600` `missing_from_statement` auto-resolves when the transaction stops being pending (`09` test). Re-processing `unknown_card` SMS when a statement registers the card: deferred |
| DB-19 | partly fixed | the line's merchant is resolved once per line in the matcher; `resolve_merchant`'s write-on-read: deferred |
| DB-26 | partly fixed | `field_groups` validated on write (`09` test); examples ≥ 1, sender scoping, per-profile LLM templates: deferred |
| DB-27 | fixed (no dedicated test) | `…1600` a line displaced by a manual link gets its own transaction; linking onto a confirmed (locked) line is refused |
| DB-32 | partly fixed | indexes on `transactions.stmt_code/related_txn_code/rule_code`, `statement_lines(profile_code, legacy_fingerprint)` |
| DB-33 | fixed | with DB-02 (`08` test) |
| DB-42 / X-08 | fixed | `private.lock_profile` (`pg_advisory_xact_lock(hashtext(profile_code))`) taken first in `ingest_parsed_document`, `ingest_sms`, `resolve_review`; `09` checks the lock is held. True concurrency not exercised in pgTAP |
| DB-43 | fixed (no dedicated test) | card branch without last4 binds the SMS to the chosen account and matches it |
| X-07 | fixed locally | `config.toml [api] max_rows = 2000`. **Prod:** Dashboard → API → Max rows = 2000 |
| WEB-04 | DB side fixed | sign-ups off in `config.toml`; the web's `shouldCreateUser: true` is for the web agent |
| DP-01 | fixed | `…1600` `statement_lines.source_doc_codes`: a document only withdraws its own evidence; another document of the same statement adds lines, fills null header fields only, never touches the header without rows; `09` tests |
| DP-02 | fixed | same mechanism: history windows union by `(line_key, occurrence)`; `09` tests |
| DP-06 | fixed | orphan reviews raised and answered in the same transaction are deleted; after re-parsing the rehearsal's ADCB/SIB documents, open orphaned reviews 150 → 0 |
| DP-08 | fixed | recon `n/a` for history extracts (CHECK extended), `warn` for an empty statement whose header shows activity or whose lines were all superseded; `09` tests |
| DB-18, DB-20–DB-25, DB-28 (now addressed by the hermetic suites), DB-29–DB-31, DB-34–DB-41, DB-44, DB-45 | deferred | P2/P3, outside the functions touched here |

Rehearsal re-run (33 hussain ADCB/SIB documents re-parsed through the worker after the fix): legacy-line
coverage ADCB 80.8 % → 100 %, SIB 53.2 % → 100 % (ENBD 89.4 % unchanged: DP-03 parser), 0 orphaned
transactions, 7 card-less empty ADCB documents parsed with a "skipped" warning.

**P2/P3 pass (2026-10-09).** Migrations `20261009000100_db_ledger_fixes`, `…0200_db_categorisation_and_jobs`,
`…0300_db_sms_templates`, `…0400_db_ops_and_worker_rpcs`, `…0500_db_identity_and_legacy`; tests
`13`–`18`. `supabase test db`: 18 files, 691 tests.

| ID | Status | Where |
|---|---|---|
| DB-17 | fixed | `9-100` `private.reprocess_waiting_sms` at the end of `ingest_parsed_document`; `13` test |
| DB-18 | fixed | `9-100` `public.prev_month_to_date_end`; `13` tests for 30 Mar / 31 Dec |
| DB-19 | fixed | `9-100` select first, insert only for a new key; `merchant_aliases` kept for manual merges; `13` test |
| DB-20 | fixed | `9-100` scalar sub-queries on `transaction_evidence_txn_idx`, evaluated for the page only (50-row page: 50 index probes, 2.7 ms vs 7–8 ms); `13` test |
| DB-21 | fixed | `9-500` `delete_profile`, `storage_cleanup` queue, `trg_audit` skip; `17` test. The worker drains `storage_cleanup` (Edge + CI pass: `20261009100100_storage_cleanup_worker`, test `19`) |
| DB-22 | fixed | `9-300` targeted re-processing (sender, scope, newest first, live pattern changes only). Moving it to a queue: not needed at 500 bounded messages |
| DB-23 | fixed | `9-500` confirmed-email triggers and `add_profile_member`; `17` tests |
| DB-24 | fixed | `9-200` whole-word seed rules, guarded update of untouched seed rules; `14` tests |
| DB-25 | fixed | `9-200` per-profile isolation, `private.job_errors`; `14` test |
| DB-26 | fixed | `9-300` examples ≥ 1, bank-sender patterns, per-profile LLM templates, `promote_sms_template`; `15` tests |
| DB-28 | fixed | `18` DB-27 and DB-43 tests. A two-connection concurrency test is not possible in pgTAP; the lock is checked as held (`09`) |
| DB-29 | fixed | `9-200` `spend_pace`, `new_recurring`, `large_transaction`, `review_backlog`; `14` tests. `amount_drift` stays reserved (decision: `auth_amount` already shows the difference) |
| DB-31 | fixed | `9-200` `preview_rule(…, p_rule_code)`; `14` tests |
| DB-32 | fixed | `9-100` `statement_lines_fx_estimate_idx`; `anomalies` with window frames (same output, checked against the old function on the demo profile) |
| DB-34 | fixed | `9-100` declined → `ignored` (rows migrated). `profiles.timezone` / `base_currency`: decision, kept and documented as reserved (Asia/Dubai is the business rule) |
| DB-35 | accepted | ~79 random bits per code is plenty |
| DB-36 | fixed | `9-100`; `13` tests |
| DB-37 | fixed | `9-200` `merchant_category_skips`; `14` tests |
| DB-38 | fixed | `9-400` 7-day windows, bounded cron scan; `16` tests |
| DB-39 | fixed | `9-100`; `13` tests |
| DB-40 | deferred | Needs an accept step and UI; goes with NEW-1 (in-app invite) |
| DB-41 | decision | no squash (all migrations are in production); Appendix A updated |
| DB-44 | fixed | `9-100` new transactions are inserted fully derived, so each is categorised once |
| DB-45 | fixed | `9-100` `overview.pending_unpriced_count`; `13` test |

**Docs follow-up (2026-10-08, docs pass):** ARCHITECTURE §4 no longer claims a 120 s statement
timeout or a regex statement timeout (DB-13), §6 lists only the insight kinds actually generated
(DB-29, partly), and PRODUCTION §2.2 no longer says "RLS isolates any stray account" (DB-04): sign-ups
are off and members are invited. Everything still open is in [BACKLOG.md](BACKLOG.md).
