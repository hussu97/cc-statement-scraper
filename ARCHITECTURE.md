# Architecture — Bank Ledger (v2)

Bank Ledger is a personal credit-card ledger for two people (and their household). Bank SMS alerts
feed it in near real time, statement PDFs reconcile it, and categorisation and analytics run
in the database. This document describes v2. The legacy v1 stack was removed after the cutover;
what remains of it (the `legacy` database schema) is summarised at the end.

Related docs: [README.md](README.md) (setup, commands, env vars), [PRODUCTION.md](PRODUCTION.md)
(deployment, operations and the cutover record), [docs/contracts/parse-v1.md](docs/contracts/parse-v1.md) (parser ⇄ worker contract).

---

## 1. System diagram

```
 iPhone (SwiftUI, apps/ios)                 Scraper CLI (local Playwright, scraper/)
  • Shortcuts automation → LogBankSMSIntent    • multipart upload, service token ccs_…
      → App Group outbox → rpc ingest_sms ─┐            │
  • Statements upload / "Add to Bank Ledger"│            │       Gmail ──Pub/Sub push (OIDC)──┐
    share extension ───────────────────────┤            │       Outlook ◀─Graph delta poll──┐ │
                                           │            │                                   │ │
 Web (Vite + React, apps/web, Vercel)      │            ▼                                   │ │
  • supabase-js + Realtime ───────────────┤   ┌──────────────── Supabase Edge Functions (Deno) ──────────┐
                                           │   │ statements-upload  sms-ingest  gmail-push  outlook-poll ◀─┘ │
                                           │   │ gmail-watch-renew  worker  ops-monitor  fx-rates           │
                                           │   └────────┬───────────────────────────┬───────────┬──────────┘
                                           ▼            │ service-role RPCs          │           │ signed URL +
                              ┌──────────── Supabase Postgres 17 ───────────────┐   │           │ X-Parser-Secret
                              │ public: tables + RLS, RPCs, views (v_spend)      │◀──┘           ▼
                              │ private: matcher, ingest, recategorize, nightly │      Cloud Run `ccs-parser`
                              │ authz: membership helpers used by RLS            │      (Python, stateless /parse,
                              │ pgmq queues · pg_cron · pg_net · Vault · Realtime│       no DB access)
                              └───────────────┬──────────────────────────────────┘
                                              │ pg_cron → pg_net → Edge Functions (x-cron-secret)
                              Supabase Storage bucket `statements` (PDFs as received)

 Sentry: `credit-card-ledger-backend` (Edge Functions + parser) · `credit-card-ledger-apps` (web + iOS)
```

Hosting is free-tier: Supabase (DB, Auth, Storage, Edge Functions, Realtime), Cloud Run (parser,
scales to zero), Vercel Hobby (web) and TestFlight (iOS). The scraper runs only on a laptop.

---

## 2. Components and responsibilities

| Component | Path | Responsibility |
|---|---|---|
| **Database** | `supabase/migrations/` | All state and all business logic: schema, RLS, ingestion, matching, reconciliation, categorisation, analytics, insights, queues, cron. |
| **Edge Functions** | `supabase/functions/` | HTTP ingress and I/O. They authenticate callers, store PDFs, call the parser and Claude, poll mailboxes and report health. They hold no business rules beyond input validation. |
| **Parser** | `services/parser/` | Stateless `POST /parse`. Downloads a PDF from a signed URL, decrypts it with candidate passwords, detects the bank (scoring legal-name and brand markers outside transaction rows, so a merchant naming another bank doesn't win) and returns normalised statements (contract parse-v1). Each parse runs in a resource-limited child process (15 MB, 30 pages, 32 MB inflated, 30 s CPU, 60 s wall), and the output is validated against the DB's constraints before it is returned. It never touches the DB. |
| **Web app** | `apps/web/` | Vite + React 19 + TanStack Router/Query + supabase-js, Tailwind v4 on `@ledger/tokens`. Renders RPC results. It never computes money. |
| **iPhone app** | `apps/ios/` | SwiftUI app, `LedgerKit` package, `LogBankSMSIntent` App Intent, "Add to Bank Ledger" share extension. |
| **Design tokens** | `packages/tokens/` | One `tokens.json` generates CSS variables, a chart palette module and `Tokens.swift`. |
| **DB types** | `packages/db-types/` | `supabase gen types` output. Never hand-written; CI checks for drift. |
| **Scraper** | `scraper/` | Local-only Playwright CLI that downloads statements and uploads them to `statements-upload`. Its architecture is frozen. |

### Edge Functions

All functions set `verify_jwt = false` in `supabase/config.toml` and authenticate the caller in
code (`_shared/auth.ts`). Every `index.ts` wraps its handler in `withSentry(name, handler)`, and
a `deno test` guard enforces this.

| Function | Caller and auth | What it does |
|---|---|---|
| `statements-upload` | Scraper: `Bearer ccs_…` service token with scope `statements:upload`, optional `X-Profile-Key`. Web/iOS: user JWT plus `profile_code` (owner only). | Accepts multipart `files` (PDF only, ≤ 20 files and ≤ 40 MB per request, enforced while streaming, before form parsing), dedups on sha256 per profile, writes the object to Storage **before** the `documents` row. The insert trigger then enqueues `parse_document`. Returns `{uploads:[{filename, doc_code, status: queued|duplicate}]}`. |
| `sms-ingest` | User JWT plus `profile_code`, or a service token with scope `sms:ingest` | Batch of ≤200 messages → `ingest_sms`. Idempotent on `client_msg_id`. For automations and tools; the iOS app calls the `ingest_sms` RPC directly. |
| `worker` | pg_cron (`x-cron-secret`) | pgmq consumer. `parse_document` → parser → `ingest_parsed_document`; `llm_categorize` → Claude → `apply_llm_suggestions`; `sms_fallback` → Claude → `propose_sms_template`. Only contract errors are permanent; everything else retries with backoff and dead-letters after 5 attempts (§4). A round starts only if it can finish inside the Edge wall clock (`EDGE_WALL_CLOCK_MS`, 150 s: a parse round needs `PARSER_TIMEOUT_MS` + 20 s, an LLM round 65 s). Returns 202 and works in the background (pg_net times out at 5 s). |
| `gmail-push` | Google-signed OIDC token from Pub/Sub (audience `GMAIL_PUSH_AUDIENCE`, SA `GMAIL_PUSH_SA_EMAIL`) | `history.list` from the stored cursor, matches PDF attachments to the mailbox's routes and stores them (`source = gmail`). Returns 500 to make Pub/Sub redeliver; redelivery is idempotent. |
| `gmail-watch-renew` | pg_cron daily | Renews `users.watch` (watches expire after 7 days) on `GMAIL_PUBSUB_TOPIC`. |
| `outlook-poll` | pg_cron hourly | Microsoft Graph delta over Inbox, DeletedItems and Archive. Resumable within `OUTLOOK_BUDGET_MS`. Replaces the legacy GitHub Actions cron. |
| `ops-monitor` | pg_cron every 15 min | Reads `ops_health()` and raises one Sentry issue per problem type, then sends the `ops-heartbeat` cron check-in. |
| `fx-rates` | pg_cron daily 21:00 UTC | Fetches open.er-api.com, inverts quotes to AED per unit with exact decimals, calls `upsert_fx_rates` (which re-estimates pending SMS). |

Shared code in `_shared/`: `auth.ts` (JWT, service token and cron secret), `sentry.ts`
(per-request scope, trace continuation, PII scrubber), `documents.ts` (PDF validation and
storage), `email_ingest.ts` and `email_routes.ts` (route matching ported from legacy),
`gmail.ts`, `oauth.ts`, `llm.ts` (Anthropic structured outputs, validated in code), `cors.ts`
and `deps.ts` (pinned imports).

---

## 3. Data model

Conventions (enforced by pgTAP guards; see CLAUDE.md §1):
- Every PK is `<x>_code text` (prefix + 26-char lowercase ULID from `public.gen_code`).
  Reference data uses natural codes (`bank_code = 'FAB'`, currencies).
- Statuses are `text` + `CHECK`. There are no enums.
- Money is `numeric(14,2)` and FX is `numeric(18,8)`.
- Time is `timestamptz`. Business dates are `Asia/Dubai` calendar dates (`public.dubai_date()`).
- Every table carries `profile_code`, child tables included, so RLS is a single predicate.
- **Tenant integrity is structural.** Each parent has `UNIQUE (profile_code, <code>)` and every
  child references it through a **composite FK** `(profile_code, <parent>_code)`: cards,
  statements, statement lines, SMS, transactions (including related, rule and recurring
  links), evidence, reviews, recon and email routes. A child can only point at a parent of its
  own profile, and every code-taking RPC also checks the code belongs to the caller's profile.
  `08_tenant_isolation.test.sql` holds the negative cross-profile tests. (The old single-column
  FKs were dropped so PostgREST sees one relationship per pair.)

```
auth.users ─< profile_members >─ profiles ─┬─ profile_state (rules_version)
                                           ├─ service_tokens (sha256 only, scopes)
                                           ├─ accounts ─< cards           (banks: global)
                                           ├─ documents ─< statements ─< statement_lines
                                           ├─ sms_messages ──> sms_templates (global, per bank)
                                           ├─ transactions ─< transaction_evidence >─ statement_lines | sms_messages
                                           │      │  └─ merchant_code ──> merchants (global) ─< merchant_aliases
                                           │      └─ *_category_code ──> categories (1-level tree)
                                           ├─ category_rules, merchant_profile_category
                                           ├─ match_reviews, statement_recon
                                           ├─ budgets, recurring_series, insights, audit_events
                                           └─ email_mailboxes ─< email_routes, email_events
fx_rates (global)
```

| Table | Notes |
|---|---|
| `profiles` | A ledger (`key` is the legacy `X-Profile-Key`, e.g. `alice`). |
| `profile_members` | `(profile_code, user_id)`, role `owner` or `viewer`. Pending invites live in `private.pending_members` and are claimed by an `auth.users` insert trigger when the user is created. Self sign-up is disabled (§8), so that user is created by an Auth invite. |
| `service_tokens` | `ccs_<hex>` tokens. Only the sha256 is stored. Scopes are `statements:upload` and `sms:ingest`, each tied to one profile. |
| `banks` | FAB, ADCB, ENBD, EIB, SIB, MASHREQ, plus their SMS sender ids. |
| `accounts`, `cards` | Credit-card accounts (kind `credit_card` only) and their cards by `last4`. A replacement card is a new card on the same account. |
| `documents` | One PDF as received: `sha256` unique per profile, `source` scraper/upload/ios/gmail/outlook/legacy, `parse_status` queued/parsing/parsed/failed. Stored at `statements/<profile_code>/<doc_code>.pdf`. |
| `statements` | `kind` is `statement` or `history_extract` (SIB history exports). Identity is `(account, statement_date)` per kind among active rows. Holds totals, due date, min due and credit limit. `doc_code` is the document that currently evidences it; several documents can evidence one statement (§4). |
| `statement_lines` | **Immutable evidence.** `line_key` is a sha256 of the raw facts and `occurrence` is the ordinal among identical keys, so two identical coffees are two lines. Only `is_current`, `superseded_at` and `source_doc_codes` change. `source_doc_codes` lists the documents whose parse contains the line; it stays current while any of them does. Carries `fx_rate` and `legacy_fingerprint`. |
| `sms_templates` | Data-driven regex per bank (sender and body patterns, `field_groups`, `msg_kind`, `priority`, `examples`). A BEFORE trigger rejects a template unless every example parses to its `expect`, `field_groups` are valid, and patterns are bounded (≤ 1000/200 chars, no back-references). Members see only templates for their banks, their messages or their proposals; `examples` is not readable by clients. |
| `sms_messages` | Raw SMS (OTPs never arrive), body ≤ 2000 chars. `client_msg_id` is unique per profile. Parsed fields, `parse_status` pending/parsed/ignored/unparsed/failed (`ignore_reason = error:<sqlstate>` when processing raised). |
| `transactions` | The canonical ledger. Derived facts (status pending/posted/void/orphaned, dates, amounts, FX, merchant) come from evidence via `private.refresh_transaction()`. User fields: `manual_category_code`, `notes`, `exclude_from_spend`. |
| `transaction_evidence` | Links a transaction to a statement line, history line or SMS. `role` primary/auth/post/reversal/duplicate, `method` new/exact/scored/tie/manual/legacy, `is_active`, `is_locked`. A line or SMS has at most one active link, and a transaction has at most one active statement line and one active history line. |
| `match_reviews` | Human decisions: ambiguous, low_score, orphaned, missing_from_statement, period_overlap, unknown_card, unparsed_sms. (`amount_drift` is allowed by the CHECK but nothing raises it yet.) |
| `statement_recon` | Per-statement checks and an ok/warn/fail/n/a status (§4). |
| `merchants`, `merchant_aliases` | Global rows, but a member reads only merchants referenced by their profiles' transactions, merchant choices or recurring series. `merchant_key()` strips payment-wallet prefixes, cities/countries and trailing digits. |
| `categories`, `category_rules`, `merchant_profile_category` | Per profile. Categories are archived, never deleted. Rules are exact/prefix/contains/regex with optional conditions, validated on write (known keys and types, own `card_code`, pattern ≤ 200 chars, no back-references). Merchant categories come from a user's manual choice or an LLM suggestion. |
| `budgets`, `recurring_series`, `insights`, `audit_events` | Monthly budgets (total or per category), detected subscriptions, the nightly insight feed, and an audit trail of user edits. |
| `email_mailboxes`, `email_routes`, `email_events` | Mailbox (gmail/outlook, `sync_state` cursor), per-bank routing rules, and per-attachment idempotency log. |
| `fx_rates` | Global AED-per-unit market rates (fallback estimate only). |

Queues (pgmq): `parse_document`, `llm_categorize`, `sms_fallback`, each with a `_dlq`.
Storage: private bucket `statements` (25 MB limit, `application/pdf`). Members can read their
profile's folder. Only Edge Functions write to it.

---

## 4. Evidence, transactions and matching

Evidence is the raw source: statement lines, history lines and SMS. It is never edited. A
transaction is a derived view over its best active evidence, in the order **statement line >
history line > SMS**. Linking or unlinking evidence calls `refresh_transaction`, which recomputes
the transaction's facts:

- With a statement or history line, the transaction is `posted`. The statement's amount, posting
  date and real `fx_rate` win. When an SMS is also linked, the SMS amount is kept as
  `auth_amount` if it differs and the SMS time becomes `txn_at`.
- With only an SMS, it is `pending`. A foreign amount gets an **estimated** AED value
  (`amount_aed_is_estimate`).
- With no evidence, it is `orphaned`. The transaction is never deleted, so its manual category
  and notes survive, and an `orphaned` review opens.

### Statement path

`document → parse_document queue → worker → parser /parse → ingest_parsed_document(doc, payload)`
runs in one DB transaction. It takes the **per-profile advisory lock** first
(`private.lock_profile`: `pg_advisory_xact_lock(hashtext(profile_code))`), as do `ingest_sms` and
`resolve_review`, so concurrent ingests for one profile serialise and can't create duplicate
accounts or cards or deadlock (the bulk legacy import parses several documents at once). There
is no function-level `statement_timeout`: Postgres arms the timer when the outer statement
starts, so a `SET` on a function never applied. Regex cost is bounded on write instead (rule
and template pattern caps, no back-references, SMS bodies ≤ 2000 chars), and the caller's role
timeout applies.

1. **Account resolution.** `resolve_statement_account` finds or creates the account and card
   from bank + primary last4. Without a last4 it never invents an account: the account this
   document already produced, else the bank's only active account, else an explicit statement
   reference seen on exactly one account, else a permanent `22023`. A card-less statement with
   no rows (the ADCB companion PDF) is skipped with a document warning.
2. **Lines are a union over documents.** One statement can be evidenced by several documents:
   the same PDF from email and the scraper, a card-less companion PDF, or overlapping SIB
   history windows. Lines are diffed on `(line_key, occurrence)`, and each line records the
   documents that contain it in `source_doc_codes`:
   - A line already present gains the document; its codes and evidence are kept.
   - New lines are inserted. A line that reappears (for example after a parser fix) is
     re-activated.
   - A document can only withdraw **its own** evidence. A line leaves the ledger
     (`is_current = false`, evidence deactivated, transaction refreshed, possibly orphaned)
     only when no document contains it any more, i.e. on a **re-parse of the same document**.
     Another document for the same statement or history cycle never supersedes lines; it may
     fill header fields that are still null, and a document without rows never touches the
     header.
   - When a re-parse no longer produces a statement it produced before (a corrected date or
     account), the document's evidence is withdrawn from it, and a statement left with no
     current lines is retired (`superseded`, `superseded_by` null). A later re-parse that
     produces it again revives it with its codes intact.
3. **History extracts.** SIB history exports are `kind = history_extract` and their lines are
   `history_line` evidence. A transaction may hold one statement line **and** one history line,
   so a history row and the real statement row land on the same transaction and are never
   double-counted. Statement amounts win. History windows are additive (rule 2).
4. **Matching.** `match_statement_lines` runs (below).
5. **Period overlap.** Overlap of more than 3 days with another active real statement of the
   same account opens a `period_overlap` review. Nothing is superseded automatically;
   `resolve_review {"supersede": …}` does that, and only for a statement that is one of the
   review's candidates, on the same profile and account, and not the subject itself.
   When a statement stops being active by any path (supersede, re-parse retirement), a trigger
   dismisses open reviews about it and any `period_overlap` review left with no active
   candidate (FV-03).
6. **Reconciliation.** `reconcile_statement` runs (below).

The worker treats a parser response as permanent only when it is a 422 carrying one of the
contract's permanent codes (`PDF_DECRYPT_FAILED`, `UNSUPPORTED_*`, `BANK_UNDETECTED`,
`DOWNLOAD_FAILED`, `INVALID_REQUEST`, `PARSE_TIMEOUT`, `PDF_TOO_LARGE`, `PARSE_OUTPUT_INVALID`),
and an ingest error as permanent for SQLSTATE class 22, `23502` and `23514`.
`fail_document(permanent)` then marks the document `failed`. Everything else, including
404/403 from a wrong `PARSER_URL`, is transient: the message is re-sent with backoff (60 s,
5 min, 15 min, 30 min) and dead-lettered after 5 attempts. See
[parse-v1](docs/contracts/parse-v1.md#worker-classification). Owners can call
`requeue_documents` after a parser fix.

### SMS path

`ingest_sms(profile, [{client_msg_id, received_at, sender, body}])` validates, stores and
processes **each message on its own**, so one bad message never fails the batch. Every message
gets its own result status: the `process_sms` outcome (for example `unknown_card`, `held`,
`ignored`, `unparsed`); `duplicate_delivery` for a `client_msg_id` already stored;
`rejected_otp` (defence in depth: OTPs are dropped on the device); `invalid` with a `reason`
when the shape is wrong (missing `client_msg_id`, empty or over-long body, bad `received_at`);
or `failed` with `reason = error:<sqlstate>` when processing raised (the message is kept with
`parse_status = failed`). Clients (the iOS outbox) park only that message. `process_sms`:

1. `match_sms_template` takes the first active template by `priority` whose sender and body
   regex match. A template whose date fields don't form a real date (`31/02/26`) does not
   apply; it never raises.
   - **No template matches:** the message is `unparsed` and an `sms_fallback` job is enqueued.
   - **`other` / `debit_card`:** the message is `ignored`. Approval prompts, due reminders,
     logins and debit-card or account alerts are seeded at priority 900+ so they never reach
     the LLM.
   - **`declined`:** stored and ignored.
2. The template's date and time give `event_at`, otherwise `received_at`. The card is resolved
   by bank + last4. When there is no last4, the bank's single active account is used.
   - **Unknown card:** an `unknown_card` review opens. Resolving it registers the card and
     re-processes every message waiting on it.
3. `match_sms` runs for purchase, preauth, refund, reversal and payment messages.

Adding or changing a template re-runs every `unparsed` message (`trg_sms_templates_reprocess`),
so a new bank format needs an INSERT, not a deploy.

### Matcher

Matching is deterministic and greedy over a temp candidate table.

**Candidates** must share the profile, account and direction (joined on
`(profile_code, account_code)`), have no active evidence of the same type, and fall within
±3 days on `txn_date` (or ±1 day on posting date when both are known).

**Score (0–100)** from `private.match_score`:

| Component | Points |
|---|---|
| Amount, same currency and exactly equal | 50 |
| Amount in a different currency, AED values within 1% / 4% | 40 / 30 |
| Amount, variable-amount merchant (fuel, hotels, car hire) or a `preauth` SMS, ratio 0.3×–1.5× | 35 |
| Date: same day / ±1 / ±2 / ±3 (or posting date ±1) | 25 / 20 / 12 / 5 |
| Merchant: same `merchant_code`, otherwise 15 × pg_trgm `similarity` | 15 |
| Card: same last4 / either unknown. A different last4 rejects the pair. | 10 / 5 |

A missing amount or date component rejects the pair.

**Outcome:**
- **Auto-link** when the score is ≥ 75 and no *materially different* competitor is within 15
  points. Method is `exact` at ≥ 85, otherwise `scored`. A competitor whose merchant affinity
  (trigram or word similarity) is at least 0.3 below the pair's is not a competitor, so
  "AED 100 at ENOC" and "AED 100 at Carrefour" on the same day pair up without a review.
- **Review** (`low_score` or `ambiguous`) when the score is 55–75 or a different competitor is
  within 15 points. The top 5 candidates are stored and the evidence is held until resolved.
- **New transaction** when the score is below 55.

**Ties.** Identical candidates (the same `line_key` on one side, or the same
amount/currency/date/merchant signature on the other) are interchangeable rather than
ambiguous. They pair in order (score, date distance, `line_no`, creation time) with
`method = tie`, so two same-day coffees with two SMS make two transactions and no review.

**Re-parse lineage and date proximity** (FV-02, migration `…2000`):
- A candidate transaction that was previously evidenced by the same line, by a line with the
  same identity (`line_key` + `occurrence`), or by a line of the same source document with the
  same date and amount is that line's own transaction coming back. A re-parse that moves a
  document's lines to a new statement (a corrected statement date) relinks them. Lineage pairs
  (score ≥ 75) are matched first, and a rival without lineage does not make them ambiguous.
- For a same-day pair, a rival one or more days away is not a conflict when that rival has its own
  same-day partner scoring at least as well. Same-amount purchases on consecutive days each take
  the transaction on their own date.

**SMS-specific rules** (`match_sms`):
1. **Duplicate alert.** Same account, kind, amount and currency, and either an identical body
   hash or (Δ event ≤ 3 min and description similarity ≥ 0.8), received within 10 min. Two
   alerts with different available limits are never duplicates. The message links as
   `role = duplicate`.
2. **Late SMS.** An SMS for a transaction a statement already posted links as `role = auth`.
3. **Otherwise** a new `pending` transaction is created. A `reversal` SMS gets `related_txn_code`
   pointing at the matching debit from the last 30 days.

**Reversals and released authorisations.** The nightly job voids a pending purchase and its
pending reversal once a later real statement closes at least 3 days after both without either
appearing (`void_released_authorisations`). If a line arrives later, refresh re-opens the
transaction.

**FX** (`private.estimate_fx`, used for pending SMS and lines without an AED amount). Sources
are tried in order:
1. The profile's most recent statement `fx_rate` for that currency. It includes the card's real
   markup.
2. The AED/USD peg, 3.6725.
3. `public.fx_rates`, the daily market rate from the `fx-rates` function.

After each FX update, pending SMS transactions are re-estimated. All three stay
`amount_aed_is_estimate = true` until a statement posts the real amount.

### Reconciliation

`statement_recon.checks` holds:
- line count
- Σ debits and Σ credits against the extracted `total_debits` / `total_credits`
- `opening + debits − credits = closing`
- held lines
- SMS coverage (share of purchase lines that also have an SMS)
- `unmatched_sms`: pending SMS transactions dated inside the period, up to 3 days before its
  end. Each one also opens a `missing_from_statement` review.

Lines without a printed AED amount (`amount_aed` null, e.g. FX rows) are counted at their
printed rate and reported as `unpriced_lines`.

Status:
- **fail:** any totals mismatch beyond 0.01 that the unpriced lines don't explain.
- **warn:** totals were not extracted; held or unmatched items exist; a mismatch is explained by
  unpriced lines; or the statement has no current lines although its header shows activity, or
  all its lines were withdrawn.
- **n/a:** history extracts. They are windows with no totals, so there is nothing to reconcile.
- **ok:** otherwise.

A `missing_from_statement` review resolves itself once its transaction stops being pending.

---

## 5. Categorisation

Category columns on `transactions`:
- `manual_category_code` (user)
- `merchant_category_code` + `merchant_category_source` (manual | llm)
- `rule_category_code` + `rule_code` + `rules_version`
- `effective_category_code`, a **generated stored** column

**Precedence:** transaction manual > merchant manual ("apply to merchant") > rule > LLM merchant
suggestion. Background recompute (`private.recategorize`) writes only the `rule_*` and
`merchant_*` columns, so a manual choice cannot be overwritten.

**Rule selection.** A LATERAL join over active rules matches each transaction's normalised
description (`exact`, `prefix`, `contains` or `regex`) and any `conditions` (`amount_min`,
`amount_max`, `bank_code`, `card_code`, `currency`, `kind`, `direction`). The winner is the
lowest `priority`, then the longest pattern, then exact > prefix > contains > regex. One
set-based `UPDATE … WHERE … IS DISTINCT FROM` applies the results.

**Recompute triggers:**
- new transactions (statement-level trigger on the transition table)
- transactions whose matchable facts change
- any `category_rules` insert, update or delete: bumps `profile_state.rules_version` and
  recomputes the profile synchronously
- a `merchant_profile_category` change: recomputes that merchant's transactions

**Cron:**
- `ledger-recategorize-sweep` (every 3 h at :17) recomputes rows whose `rules_version` is stale.
- `ledger-llm-enqueue` (22:30 UTC nightly) batches uncovered merchants in groups of 25 into
  `llm_categorize`, re-asking only when the category set hash changes.

**LLM.** Claude Haiku (`LLM_MODEL`, default `claude-haiku-5-5`) receives only merchant names, up to
3 example descriptions per merchant and the category list. It never sees amounts or PDFs.
Suggestions below 0.5 confidence are dropped and never override a manual merchant choice. When
`ANTHROPIC_API_KEY` is unset, the worker leaves the LLM queues alone and warns once.

**Other pieces:**
- **Rule preview.** `preview_rule` reports "this rule would change N transactions" without saving.
- **Seeding.** Default categories and rules (from the legacy `category_rules.yaml`) are copied
  into a profile once, by `create_profile` / `seed_profile_defaults`.

---

## 6. Analytics and insights

There is **one definition of spend**: `public.v_spend` (`security_invoker`). It counts debit
purchases, fees, interest and cash advances, minus refunds. It excludes payments, transfer,
ignore and income categories, void and orphaned transactions, and anything marked
`exclude_from_spend`. Buckets use `txn_date`, a Dubai date. Every analytics RPC builds on it.
Clients render results and never re-derive money.

Analytics RPCs (all security invoker, so RLS applies):

| Group | RPCs |
|---|---|
| Overview and trends | `overview`, `spend_series` (grain, group_by, optional `p_top` with an "Other" fold) |
| Breakdowns | `category_breakdown`, `merchant_leaderboard`, `daily_spend`, `hour_weekday_pattern` |
| Currency and cycles | `fx_spend`, `statement_cycles`, `yoy_compare` |
| Exceptions and metadata | `anomalies`, `filter_meta` |
| Budgets and recurring | `budget_status`, `recurring_list` |

`v_transactions` is the Activity read model. It carries category source, evidence flags
(`has_sms`, `has_statement`), bank and last4.

The nightly job `private.nightly()` (22:00 UTC = 02:00 Dubai) runs three steps:
1. Voids released authorisations.
2. Detects recurring charges: ≥ 3 charges (≥ 2 for yearly) at a weekly, monthly or yearly
   cadence with amount CV below 10%.
3. Generates the deterministic, deduplicated insight feed. Today it emits five kinds:
   `category_spike`, `budget_risk`, `price_change`, `statement_due` and `uncategorized`. The
   CHECK also allows `spend_pace`, `new_recurring`, `review_backlog` and `large_transaction`,
   which are reserved: nothing generates them yet (docs/audit/BACKLOG.md, DB-29).

---

## 7. Queues, cron and Vault

| pg_cron job | Schedule (UTC) | Action |
|---|---|---|
| `ledger-worker-kick` | `* * * * *` | `private.kick_worker()` calls the `worker` function, only when a queue has visible messages |
| `ledger-recategorize-sweep` | `17 */3 * * *` | `private.recategorize_stale()` |
| `ledger-fx-rates` | `0 21 * * *` | `fx-rates` function |
| `ledger-nightly` | `0 22 * * *` | `private.nightly()` |
| `ledger-llm-enqueue` | `30 22 * * *` | `private.enqueue_llm_categorize()` |
| `ledger-legacy-choices` | `45 22 * * *` | `private.legacy_choices_cron()`: applies staged legacy category choices once per transaction (never over a later user edit), then unschedules itself when nothing is pending or 30 days after staging. Leftovers: `private.legacy_unmatched_choices()` |
| `ledger-cron-history-purge` | `50 23 * * *` | deletes `cron.job_run_details` older than 7 days |
| `ledger-ops-monitor` | `*/15 * * * *` | `ops-monitor` function |
| `ledger-gmail-watch-renew` | `0 3 * * *` | `gmail-watch-renew` function |
| `ledger-outlook-poll` | `5 * * * *` | `outlook-poll` function |

`private.invoke_edge(fn)` uses pg_net to POST to `<project_url>/functions/v1/<fn>` with header
`x-cron-secret`. It reads two **Vault** secrets:
- `project_url`
- `edge_cron_secret`, whose value must equal the `CRON_SECRET` function secret (both are set
  from `supabase/functions/.env.production` by `scripts/cutover/set-vault-secrets.sql` and
  `scripts/cutover/set-edge-secrets.sh`; PRODUCTION.md §2.4–2.5)

Without them, cron calls are skipped with a notice.

Other Vault entries are named by convention:
- `profile:<profile_code>:<KEY>`: PDF passwords (`FAB_PDF_PASSWORD`, …, `ADCB_CID`). Set
  through `set_profile_secret` and listed by key only.
- `mailbox:<mailbox_code>:refresh_token`: OAuth refresh tokens, via `set_mailbox_secret`.

Clients can set and list secrets but never read values back. Only the worker reads them, via
`worker_document_context` and `worker_mailbox_secret`.

Realtime publishes `transactions`, `sms_messages`, `documents`, `match_reviews` and `insights`.
RLS applies to every change event.

---

## 8. Auth and RLS

- **Users** sign in with Supabase Auth: email one-time code or magic link, and a password for
  the seeded demo user. Sign in with Apple is stubbed on iOS. Membership in `profile_members`
  grants access, and a profile can have several owners and viewers.
- **No self sign-up.** Bank Ledger is private: `[auth] enable_signup = false` locally, and the same
  dashboard setting in production. The web's magic link uses `shouldCreateUser: false`, so an
  unknown email gets "Ask the ledger's owner to invite you". A member is added by an owner with
  `add_profile_member` (an existing user is added at once; otherwise a pending invite is
  stored), and the person's Auth user is created by an Auth invite (Dashboard → Authentication
  → Users → Invite user, or the admin API), which works with sign-ups off. The insert trigger
  then claims the pending invite. The legacy import refuses to adopt a profile key it did not
  create (`private.legacy_import_profiles`), so a squatted key can't capture migrated data.
- **API keys.** Clients (web, iOS, scraper `apikey`) ship only the publishable key
  (`sb_publishable_…`); RLS applies and the signed-in user's JWT carries identity (Realtime
  included). Edge Functions use the secret key (`sb_secret_…`, maps to `service_role`) from the
  runtime-injected `SUPABASE_SECRET_KEYS`, falling back to `SB_SECRET_KEY` and then the legacy
  `service_role` JWT; their user clients pair the publishable key with the caller's JWT. pg_cron
  calls carry only `x-cron-secret`. The legacy anon/service_role JWT keys can be disabled once
  PRODUCTION.md §2.8 passes.
- **RLS on every table.** Policies call `authz.my_profile_codes()` or
  `authz.my_owned_profile_codes()`. These are SECURITY DEFINER functions in the `authz` schema,
  evaluated once per statement through `(select …)`. Members read; owners write the user-editable
  columns, which are granted column by column. A pgTAP guard (`01_rls.test.sql`) fails if any
  `public` table lacks RLS or a policy.
- **Client grants are explicit.** The first migration revokes `postgres`'s default privileges on
  `public` tables and sequences from `anon` and `authenticated` (production was created with
  Supabase's older `GRANT ALL` defaults, FV-01), and `…2100` re-asserts the exact grants. `anon`
  holds no table privilege at all; `authenticated` has no TRUNCATE/REFERENCES/TRIGGER and only
  column-level UPDATE on ledger and identity tables. `11_privileges.test.sql` pins the full
  privilege matrix: change it together with any client grant.
- **RPC guards.**
  - User RPCs start with `perform private.assert_member(p_profile_code, need_owner)`.
  - Edge-only RPCs (ingest, queue wrappers, worker context, `ops_health`, `upsert_fx_rates`)
    start with `perform private.assert_service_role()`.
  - Both read the `role` GUC, which survives SECURITY DEFINER. `service_role` and internal
    sessions (pg_cron, migrations) pass.
  - Internals live in `private`, which client roles have no USAGE on.
- **Why there is no `REVOKE EXECUTE`.** On Supabase Postgres **17.6.1.104**, calling a function
  the caller lacks EXECUTE on segfaults the server (reproduced locally on 2026-10-08). Functions
  therefore guard themselves in their bodies instead of relying on grants. A pgTAP guard
  enforces this. Revisit after upgrading Postgres (see PRODUCTION.md).
- **SECURITY DEFINER hygiene.** Every such function sets `search_path = ''` and fully qualifies
  names. Views are `security_invoker = true`. Both are guarded.
- **Edge Functions** use the service-role client only after authenticating the caller, and pass
  `profile_code` explicitly. Service tokens are profile-scoped, so the token itself decides the
  profile. `X-Profile-Key` is checked for consistency only, to keep the scraper contract.

---

## 9. SMS capture on iOS

iOS gives apps no access to SMS. The supported route is **one** Shortcuts personal automation:
*Message → Message contains "Card" → Run Immediately, Notify When Run **on** → Log Bank SMS*
(Message = Shortcut Input's Content, Sender = Shortcut Input's Sender). "Card" appears in every
ADCB, FAB, ENBD and SIB credit-card purchase, refund and decline format in the template seed;
a single keyword means each alert fires once. Settings → *Set up SMS capture* walks through it
and shows "Last captured" and a "Send test" button. Whether Shortcuts' "contains" is
case-insensitive (the ENBD refund says "card") still needs a real-device check.

```
Bank SMS → Shortcuts automation → LogBankSMSIntent (openAppWhenRun = false, separate process)
  → SMSCapture.classify (on device: drop OTPs, debit-card / account alerts, no-amount messages)
  → App Group outbox (fresh client_msg_id) → flush via rpc('ingest_sms') to the "SMS go to" ledger
  → per-message result; failures classified as permanent / transient / signed out
```

- **"SMS go to" ledger.** An explicit setting in the App Group, limited to ledgers the user
  owns (default: the first owned one). The App Intent, the share extension and queued PDF
  uploads use it, never the ledger currently on screen.
- **Outbox.** Errors are classified by SQLSTATE / PGRST code, then HTTP status. Transient ones
  (offline, 5xx, `57014`, `08`/`40`/`53` classes) retry with backoff for up to 8 attempts, then
  park; signed-out never uses up attempts. A permanent batch error is split until the bad
  message is alone; a `42501` parks that ledger's batch; a per-message `invalid`/`failed`
  status parks only that message. Parked messages are listed in Settings → "Not sent" with
  Retry and Delete, and Shortcut results say why a message waits.

- **Server-side parsing is data-driven** through `sms_templates`. Seed templates for ADCB, FAB,
  ENBD and SIB are built from real alerts.
- **LLM fallback.** An `unparsed` message is sent to Claude, which proposes a template. The
  proposal is stored **inactive** (`source = llm`) with the message as its example, so it must
  parse before it can be saved. An `unparsed_sms` review opens, and the template goes live only
  when an owner approves it (`set_sms_template_active`).
- **Privacy.** SMS bodies are never logged or sent to Sentry.

---

## 10. Observability (Sentry)

**Decision: two Sentry projects.**

| Project | Runtimes | Distinguishing tag |
|---|---|---|
| `credit-card-ledger-backend` | Supabase Edge Functions and the Cloud Run parser | `service` = `edge` \| `parser` (plus `function` on Edge events) |
| `credit-card-ledger-apps` | Web app and iPhone app (app, intent and share extension) | `app` = `web` \| `ios` (plus `target` on iOS) |

- `release` is the git SHA and `environment` is `local | preview | production` everywhere.
- **Local never reports.** Every runtime refuses to start Sentry when the environment is unset,
  `local`, `development` or `test` (iOS also `dev` and any Debug build; web also Vite dev
  mode), even with a DSN: `_shared/sentry.ts` `sentryActive`, `ccs_parser/sentry.py`
  `sentry_active`, web `shouldInitSentry`, LedgerKit `Telemetry.shouldStart`.
- **Distributed tracing.** Web and iOS send `sentry-trace` and `baggage` to Edge Functions,
  which continue the trace and forward it to `/parse`. An upload becomes one trace across
  client → Edge → parser.
- **PII.** `sendDefaultPii` is off. A per-runtime scrubber (each with unit tests) strips SMS
  bodies, PDF passwords, tokens, `Authorization` and `X-Profile-Key` headers, email fields,
  free-text email addresses and signed URL query strings. Edge Functions return fixed messages
  for constraint violations (23505/23503/23514), never constraint names. The web scrubs spans too (`beforeSendSpan`), because
  Sentry v11 streams spans past `beforeSendTransaction`, and its Supabase integration no longer
  re-reports failed requests. Tags carry only opaque codes. Ingest rejections carry the SQLSTATE
  and the constraint name, with literal values filtered from the PG message.
- **Database health.** The DB can't run the SDK, so `ops-monitor` turns `ops_health()` into
  issues every 15 min:
  - cron failures
  - DLQ depth > 0
  - documents stuck over 1 h
  - failed parses
  - unparsed SMS above `OPS_SMS_UNPARSED_THRESHOLD`
  - recon failures
  - review backlog above `OPS_OPEN_REVIEWS_THRESHOLD`

  It then sends the **`ops-heartbeat` cron check-in**, so a paused project or dead pg_cron alerts
  by missing it.
- **Alerts:**
  - new issue in production (both projects)
  - missed `ops-heartbeat`
  - `dlq:*` issues
  - iOS crash-free sessions below 99%, filtered `app:ios` in `credit-card-ledger-apps`

- **Per-request tags on Edge.** The Deno SDK has no async context strategy, so Sentry scopes
  are shared by concurrent requests in one isolate. `withSentry` keeps `function`,
  `execution_id` and any `setRequestTag(...)` in an `AsyncLocalStorage` that an event processor
  applies; handlers never call `Sentry.getCurrentScope().setTag` (`_tests/sentry_scope_test.ts`).
- **Tags at init.** Each runtime's Sentry helper sets its tag on every event:
  `_shared/sentry.ts` (`service=edge`), `ccs_parser/sentry.py` (`service=parser`),
  `apps/web/src/lib/sentry.ts` (`app=web`, via `initialScope`) and LedgerKit `Telemetry`
  (`app=ios`). Each has a unit test asserting it.

---

## 11. Key decisions

| Decision | Rationale |
|---|---|
| Logic in Postgres, I/O in Edge Functions | Edge Functions get 0.2–2 s of CPU. Matching and categorisation are set-based SQL and run in one transaction with the data. |
| Parser stays Python on Cloud Run | It reuses the proven pdfplumber parsers (golden parity tests). It is stateless, scales to zero and never sees the DB. |
| Evidence-based ledger | Re-ingest, parser fixes, SMS and history exports can't duplicate or delete user work, and transactions are never hard-deleted. |
| Generated `effective_category_code` | Manual precedence holds by construction, not by convention. |
| Same Supabase project as legacy | The first migration moves the legacy tables into the `legacy` schema. v2 owns `public`, data moves in-DB, and the legacy schema stays as the historical record. |
| Credit cards only | Debit and account SMS are recognised and stored as `ignored`. |
| pg_cron + pgmq instead of a job server | No always-on worker is needed, which keeps it free-tier, and daily traffic keeps the project from pausing. |

---

## Legacy v1 (removed)

v1 was a FastAPI backend with an embedded worker on Render, PDFs in GCS, a React admin panel on
Vercel, a Gmail relay on Cloud Run and a GitHub Actions cron for Microsoft mail. It shared the
Supabase project with v2. The first v2 migration moved its tables into the `legacy` schema,
and `scripts/migrate_legacy.py` (metadata, Vault secrets, PDFs, parity report) moved the data
into v2 at cutover. After the cutover the v1 code, its deploy files and workflows, and the
cutover script were deleted from the repo (git history keeps them).

What stays:
- The **`legacy` schema** in production, untouched, as the historical record. No client role
  can use it. Dropping it is a separate, explicit decision (take a final `pg_dump` first).
- The **migrations** that reference it (`…0000_quarantine_legacy`, `…0950_legacy_import`,
  `…1800_audit_visibility_and_legacy`: import, `legacy_parity_report`, `legacy_missing_lines`
  and the self-unscheduling `ledger-legacy-choices` cron).
  They are applied history; migrations are append-only.
- Provenance data in v2: `documents.source = 'legacy'`, `transaction_evidence.method = 'legacy'`,
  `statement_lines.legacy_fingerprint` and the parser's `legacy_fingerprint` output.
