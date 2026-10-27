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
| **iPhone app** | `apps/ios/` | SwiftUI app, `LedgerKit` package, `LogBankSMSIntent` App Intent, "Add to Bank Ledger" share extension, Home and Lock Screen widgets (an App Group snapshot the app writes; no network). |
| **Design tokens** | `packages/tokens/` | One `tokens.json` generates CSS variables, a chart palette module and `Tokens.swift`. |
| **DB types** | `packages/db-types/` | `supabase gen types` output, with each `Relationships` array stable-sorted so it is deterministic (`packages/db-types/scripts/gen-types.mjs`). Never hand-written; CI checks for drift. |
| **Scraper** | `scraper/` | Local-only Playwright CLI that downloads statements and uploads them to `statements-upload`. Its architecture is frozen. |

### Edge Functions

All functions set `verify_jwt = false` in `supabase/config.toml` and authenticate the caller in
code (`_shared/auth.ts`). Every `index.ts` wraps its handler in `withSentry(name, handler)`, and
a `deno test` guard enforces this.

| Function | Caller and auth | What it does |
|---|---|---|
| `statements-upload` | Scraper: `Bearer ccs_…` service token with scope `statements:upload`, optional `X-Profile-Key`. Web/iOS: user JWT plus `profile_code` (owner only). | Accepts multipart `files` (PDF only, ≤ 20 files and ≤ 40 MB per request, enforced while streaming, before form parsing), dedups on sha256 per profile, writes the object to Storage **before** the `documents` row. The insert trigger then enqueues `parse_document`. Returns `{uploads:[{filename, doc_code, status: queued|duplicate, parse_status, requeued?}]}`; a duplicate of a document whose parse failed is requeued. |
| `sms-ingest` | User JWT plus `profile_code`, or a service token with scope `sms:ingest` | Batch of ≤200 messages → `ingest_sms`. Idempotent on `client_msg_id`. For automations and tools; the iOS app calls the `ingest_sms` RPC directly. |
| `worker` | pg_cron (`x-cron-secret`) | pgmq consumer. `parse_document` → parser → `ingest_parsed_document`; `llm_categorize` → Claude → `apply_llm_suggestions`; `sms_fallback` → Claude → `propose_sms_template`; `storage_cleanup` → Storage `remove` (a deleted profile's PDFs, `statements` bucket and profile-prefixed paths only). A parse starts with `begin_document_parse`, which skips stale messages for `parsed`/`failed` documents. Only contract errors are permanent; everything else retries with backoff and dead-letters after 5 attempts (§4). A round starts only if it can finish inside the Edge wall clock (`EDGE_WALL_CLOCK_MS`, 150 s: a parse round needs `PARSER_TIMEOUT_MS` + 20 s, an LLM round 65 s). Returns 202 and works in the background (pg_net times out at 5 s). |
| `gmail-push` | Google-signed OIDC token from Pub/Sub (audience `GMAIL_PUSH_AUDIENCE`, SA `GMAIL_PUSH_SA_EMAIL`) | `history.list` (filtered to the watch label) from the stored cursor, matches PDF attachments to the mailbox's routes and stores them (`source = gmail`). The cursor advances after every page, through `save_mailbox_sync_state` (it never moves backwards). Within `GMAIL_PUSH_BUDGET_MS`; when it runs out it answers 503 and the redelivery continues. A cursor older than Gmail's history (404) is reported and followed by a bounded `messages.list` backfill. Transient failures return 500 (redelivery is idempotent); permanent ones (bad envelope, revoked grant, missing config) are recorded in `sync_state.last_error` and acked. |
| `gmail-watch-renew` | pg_cron daily | Renews `users.watch` (watches expire after 7 days) on `GMAIL_PUBSUB_TOPIC`. |
| `outlook-poll` | pg_cron hourly | Microsoft Graph delta over Inbox, DeletedItems and Archive. Resumable within `OUTLOOK_BUDGET_MS`. Replaces the legacy GitHub Actions cron. |
| `ops-monitor` | pg_cron every 15 min | Reads `ops_health()` and raises one Sentry issue per problem type, then sends the `ops-heartbeat` cron check-in. |
| `member-invite` | User JWT (owner) | Adds a member (`add_profile_member` as the caller) and, for an email with no Auth user (sign-ups are off), sends the Auth invite with the service client; `resend` re-sends to a never-confirmed member. Rate-limited per caller and per address; the invite redirects only to the caller's own origin. |
| `metal-prices` | pg_cron every 6 hours (`7 */6 * * *`) | Gold at the Dubai Jewellery Group's retail rates by karat (dubaicityofgold.com, else Khaleej Times' 24K), Dubai retail silver per kilo (Khaleej Times JSON-LD), spot gold and silver for reference (gold-api.com, else Swissquote); `record_metal_prices` converts to AED per gram and refuses a jump over 50%. |
| `stock-prices` | pg_cron Mon–Sat 22:30 UTC (`30 22 * * 1-6`), or an owner's JWT after adding a note | Daily closes of every share a structured note follows (and shares a note delivered) from Yahoo Finance's chart endpoint (no key; query2 when query1 refuses), from 5 days before the last stored close or 7 days before the note's strike, a session still trading left out; `record_security_prices`, then `settle_structured_notes` posts coupons, autocalls and maturities. A symbol it cannot price fails the cron run (Sentry). |
| `termsheet-extract` | User JWT (owner), multipart PDF | Stores the term sheet in `term-sheets`, sends it to Claude (`TERMSHEET_LLM_MODEL`, default `claude-sonnet-5-5`) as a document with a JSON schema, and normalises the answer into the termsheet-v1 draft (`docs/contracts/termsheet-v1.md`) with warnings for the review: printed levels that disagree with the initial level, half coupons or autocalls, dates out of order, a payout without a 0% branch or that falls as the worst share rises, and features it does not model. Nothing from the document is logged. |
| `rl360-sync` | pg_cron daily (`20 2 * * *`, 06:20 Dubai) | Signs in to RL360's Online Service Centre with each login in `RL360_LOGINS`, reads every plan's value and premium history (plain HTML, no browser), and calls `import_holding_data`: it claims the profile's RL360 plan by plan number, stores the value (source `import`, never over a manual one), reconciles premiums with linked card payments (±7 days, 5%; unmatched premiums become imported contributions) and returns the month-ends still without a value, which the function backfills (30 a run). |
| `fx-rates` | pg_cron daily 21:00 UTC | Fetches open.er-api.com, inverts quotes to AED per unit with exact decimals, calls `upsert_fx_rates` (which re-estimates pending SMS). |

Shared code in `_shared/`: `auth.ts` (JWT, service token and cron secret), `sentry.ts`
(per-request scope, trace continuation, PII scrubber), `documents.ts` (PDF validation and
storage), `email_ingest.ts` and `email_routes.ts` (route matching ported from legacy),
`gmail.ts`, `provider.ts` (provider HTTP errors, fast base64, attachment size limit), `oauth.ts`, `llm.ts` (Anthropic structured outputs, validated in code), `cors.ts`
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
                                           │      └─< balance_checkpoints (bank accounts)
                                           ├─ documents ─< statements ─< statement_lines
                                           ├─ sms_messages ──> sms_templates (global, per bank)
                                           ├─ transactions ─< transaction_evidence >─ statement_lines | sms_messages
                                           │      │  └─ merchant_code ──> merchants (global) ─< merchant_aliases
                                           │      └─ *_category_code ──> categories (1-level tree)
                                           ├─ category_rules, merchant_profile_category
                                           ├─ match_reviews, statement_recon
                                           ├─ budgets, recurring_series, insights, audit_events, anomaly_dismissals
                                           └─ email_mailboxes ─< email_routes, email_events
fx_rates (global)
```

| Table | Notes |
|---|---|
| `profiles` | A ledger (`key` is the legacy `X-Profile-Key`, e.g. `alice`). |
| `profile_members` | `(profile_code, user_id)`, role `owner` or `viewer`. Pending invites live in `private.pending_members` and are claimed by `auth.users` triggers once the user's email is **confirmed** (on insert when already confirmed, or on the confirmation / email change); `add_profile_member` also treats an unconfirmed account as not signed up. Self sign-up is disabled (§8), so that user is created by an Auth invite. An owner removes a whole profile with `delete_profile(p_profile_code, p_confirm_key)`, which **archives** it: `profiles.archived_at` is set, nothing is deleted (data, PDFs and Vault secrets stay), its active service tokens are revoked and its mailboxes disabled (recorded in `archive_state`). Archived profiles drop out of every membership check, so no client sees them; `restore_profile` (service role) undoes exactly that. |
| `service_tokens` | `ccs_<hex>` tokens. Only the sha256 is stored. Scopes are `statements:upload` and `sms:ingest`, each tied to one profile. |
| `banks` | FAB, ADCB, ENBD, EIB, SIB, MASHREQ, WIO (Wio Bank, no SMS sender: its alerts are app notifications), plus their SMS sender ids. `logo_path` names the bank's image in the public `bank-logos` bucket (`<bank_code>.png`); clients build `<SUPABASE_URL>/storage/v1/object/public/bank-logos/<logo_path>`. |
| `accounts`, `cards` | Credit-card accounts (kind `credit_card` only) and their cards by `last4` (and, for SMS that name a card by its BIN, `first6`). `cards.wallet_name` is the name the phone's wallet shows for the card (owner-editable, unique per profile ignoring case); Wallet payments find their card by it. A replacement card is a new card on the same account: the old card becomes `replaced` and keeps its transactions. It joins the account either by the owner (`add_replacement_card(profile, old card_code, new last4)`) or automatically for a history extract (§4, statement path step 1). |
| `documents` | One PDF as received: `sha256` unique per profile, `source` scraper/upload/ios/gmail/outlook/legacy, `parse_status` queued/parsing/parsed/failed. Stored at `statements/<profile_code>/<doc_code>.pdf`. |
| `statements` | `kind` is `statement` or `history_extract` (SIB history exports). Identity is `(account, statement_date)` per kind among active rows. Holds totals, due date, min due and credit limit. `doc_code` is the document that currently evidences it; several documents can evidence one statement (§4). |
| `statement_lines` | **Immutable evidence.** `line_key` is a sha256 of the account and the raw facts (`private.statement_line_key`; the description with whitespace collapsed and letter case ignored, since SIB's two exports print one row in different cases) and `occurrence` is the ordinal among identical keys, so two identical coffees are two lines. Only `is_current`, `superseded_at` and `source_doc_codes` change (and `account_code` with `line_key` when `private.merge_accounts` moves a line, so a re-parse still finds it) (and the text, when a private merchant mask applies: §5). `source_doc_codes` lists the documents whose parse contains the line; it stays current while any of them does. Carries `fx_rate` and `legacy_fingerprint`. |
| `sms_templates` | Data-driven regex per bank (sender and body patterns, `field_groups`, `msg_kind`, `priority`, `examples`). A BEFORE trigger rejects a template unless every example parses to its `expect`, `field_groups` are valid, and patterns are bounded (≤ 1000/200 chars, no back-references). Every template has at least one example. Members see only templates for their banks, their messages or their proposals; `examples` is not readable by clients. `scope_profile_code` limits an LLM proposal to the profile it was made for (its sender pattern is built from the bank's `sms_senders`) until an operator runs `promote_sms_template`. |
| `sms_messages` | Raw SMS (OTPs never arrive), body ≤ 2000 chars. `client_msg_id` is unique per profile. Parsed fields, `parse_status` pending/parsed/ignored/unparsed/failed (`ignore_reason = error:<sqlstate>` when processing raised; declined, debit-card and other alerts are `ignored` with the kind as reason). `source` is `sms` or `wallet` (a card payment logged by the phone's payment automation, see the Wallet path in §4); a `wallet` row, and only one, carries `wallet_pass_name`. |
| `transactions` | The canonical ledger. Derived facts (status pending/posted/void/orphaned, dates, amounts, FX, merchant) come from evidence via `private.refresh_transaction()`. User fields: `manual_category_code`, `notes`, `exclude_from_spend`. |
| `card_transfers` | A payment from one credit card to another (Wio's credit card pays other cards from its credit line, e.g. an EIB card): `from_txn_code` is the paying card's charge (`direction = debit`, `kind = payment`), `to_txn_code` the paid card's credit `payment`. `private.link_card_transfer` pairs them on every insert/update of a payment (trigger `transactions_card_transfer`): same AED amount, opposite directions, different accounts, at most 3 days apart, each the other's only candidate; a side that stops qualifying drops the link. `v_transactions` carries the other side (`transfer_txn_code`, `transfer_bank_code`, `transfer_card_last4`). Members read; no client writes. |
| `transaction_evidence` | Links a transaction to a statement line, history line or SMS. `role` primary/auth/post/reversal/duplicate, `method` new/exact/scored/tie/manual/legacy, `is_active`, `is_locked`. A line or SMS has at most one active link, and a transaction has at most one active statement line and one active history line. |
| `match_reviews` | Human decisions: ambiguous, low_score, orphaned, missing_from_statement, period_overlap, unknown_card, unparsed_sms. (`amount_drift` is allowed by the CHECK but reserved: an auth/post difference shows as `auth_amount` instead.) Clients read a page of reviews, then `review_context(profile, review_codes[])` once for all of them: per review its subject (`line`, `sms` without `body`, `txn` or `statement`), its `candidates` as `v_transactions` rows in candidate order, and an unparsed SMS's proposed `template` (client-readable columns only); SECURITY DEFINER with a member check, everything filtered by the profile, at most 2000 codes. |
| `statement_recon` | Per-statement checks and an ok/warn/fail/n/a status (§4). |
| `merchants`, `merchant_aliases` | Global rows, but a member reads only merchants referenced by their profiles' transactions, merchant choices or recurring series. `merchant_key()` strips payment-wallet prefixes, cities/countries (also when glued to the name), reference tokens, foreign amounts and trailing digits; branch names stay. After a key change, `private.rekey_merchants()` merges merchants onto survivors that keep their codes and maps old keys through `merchant_aliases`. |
| `categories`, `category_rules`, `merchant_profile_category` | Per profile. Categories are archived, never deleted. Rules are exact/prefix/contains/regex with optional conditions, validated on write (known keys and types, own `card_code`, pattern ≤ 200 chars, no back-references). Merchant categories come from a user's manual choice or an LLM suggestion. `merchant_category_skips` remembers merchants the LLM declined (per category-set hash) and suggestions an owner rejected (`reject_merchant_suggestion`), so neither is re-asked. |
| `budgets`, `recurring_series`, `insights`, `audit_events` | Monthly budgets (total or per category, for every card or one card: `account_code`), detected subscriptions, the nightly insight feed, and an audit trail of user edits. |
| `anomaly_dismissals` | Charges an owner marked "This is fine" on the Anomalies list (`dismiss_anomaly`), one per `(profile_code, txn_code)`, with `dismissed_by`; deleted with the transaction. Members read; no client writes. `anomalies` leaves these charges out. |
| `email_mailboxes`, `email_routes`, `email_events` | Mailbox (gmail/outlook, `sync_state` cursor), per-bank routing rules, and per-attachment idempotency log. |
| `document_events` | A document's timeline for the apps (`event_code` `dev_…`, `doc_code`, `stage` received/stored/duplicate/queued/parsing/parsed/ingested/failed/retry, `level` info/warn/error, `message` a sentence for end users, `detail` codes and counts only). Member read, in the Realtime publication; written only by the service role and SQL functions (§4). No FK on `doc_code`: `received`/`stored` precede the documents row. Kept 90 days. |
| `fx_rates` | Global AED-per-unit market rates (fallback estimate only). `private.bank_fx_fees` holds each bank's markup over them; `private.fx_rate_history` keeps every day's rate (backfilled from 2025-01-11). |

Queues (pgmq): `parse_document`, `llm_categorize`, `sms_fallback` and `storage_cleanup`, each with a `_dlq`;
Messages are never deleted: acknowledging (`queue_delete`), dead-lettering, `requeue_dlq` and
`drain_dlq` all `pgmq.archive`, so each message and its `dlq_reason` stay in `pgmq.a_<queue>`.
`storage_cleanup` carries `{bucket, paths[]}`; since `delete_profile` archives, nothing queues it any more
(the worker still drains it). `drain_dlq(queue)` and `requeue_dlq(queue, limit)` are the service-role
DLQ tools.
Storage: private bucket `statements` (25 MB limit, `application/pdf`). Members can read their
profile's folder. Only Edge Functions write to it. Public bucket `bank-logos` (1 MB, PNG/SVG/
WebP/JPEG) holds the bank logos named by `banks.logo_path`; no policy lets clients write it,
the operator uploads them (PRODUCTION §11).

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
  (`amount_aed_is_estimate`) from `private.estimate_fx(profile, currency, bank, date)`: the card's
  own bank's latest purchase statement rate, else the USD peg or the mid rate of that date
  (`private.fx_rate_history`, the latest day on or before it; else `fx_rates`) × (1 + the bank's
  all-in markup in `private.bank_fx_fees`: published bank fee × the ≈ 1.15% Visa/Mastercard
  charge, e.g. SIB 3.68%, ADCB 4.17%, checked against billed USD rows). Another bank's rate is never used; every bank has a markup.
  A posted line without a printed AED amount (SIB history foreign rows) is estimated the same way.
- With no evidence, it is `orphaned`. The transaction is never deleted, so its manual category
  and notes survive, and an `orphaned` review opens.
  Dismissing that review ("Mark as checked") voids it (`void_reason = 'orphan_dismissed'`).
  Orphaned rows count in no money total: spend, the Activity net or a balance.

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
   **Replacement cards.** An unknown last4 normally creates a new account. For a
   `history_extract` only (it carries no account identity, totals or reference, so it cannot
   overwrite a real statement), the card joins the bank's existing account when the profile has
   exactly **one** active account at that bank, the card type matches the account's product when
   both are known, and the extract's first transaction is not earlier than 31 days before the
   account's last current line (`private.successor_card_account`). The account's older primary
   cards become `replaced`, the timeline's `ingested` event says so, and SMS waiting as
   `unknown_card` for the new number are re-processed. Two live cards (overlapping activity or a
   different product) stay on separate accounts; anything else is registered by the owner with
   `add_replacement_card`.
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
   The parser buckets an export's rows into cycles (SIB: 15th to 14th). When the bucketing
   changes, a row arrives on a history statement with another date while it is still current
   on the old one: `private.rebucket_history_lines` moves it (the new line takes the old line's
   transaction evidence and documents; the old line stops being current), so the transaction
   keeps its code and user fields, and an old history statement left with no current line is
   superseded by the new one. An export whose cycles close on another day than
   `accounts.cycle_close_day` gets an ingest warning.
   **SMS statements.** SIB sends no statement document: its monthly statement-summary SMS
   (`msg_kind = 'statement_summary'`: outstanding amount, minimum due, due date) makes a
   header-only `kind = statement` row with `statements.sms_code` set and no `doc_code`
   (`private.apply_sms_statement`, called by `process_sms`). Its date is the cycle close on or
   before the day the SMS arrived (Dubai): `accounts.cycle_close_day`, else the day the
   account's latest history export ends on. The first summary of a cycle wins; a reminder
   leaves it alone, and a PDF for the same date takes the row over (it has no document).
   `public.v_sms_statements` pairs it with the cycle's history export (±3 days), whose lines
   are its lines, and checks the SMS closing balance against the ledger: the previous closing
   (or the BALANCE MIGRATION anchor) plus every pending or posted transaction up to the close,
   except a charge still pending on the close day (the bank closes with what has posted).
   The check is live (`statement_cycles`, `statement_detail`), so a later history upload or
   late SMS closes a gap without a re-run; `reconcile_statement` stores the same result and
   raises no `missing_from_statement` reviews for it. `statement_cycles` lists the pair as one
   row (`from_sms`), and `statement_detail` of the export opens the SMS statement.
   Wio Credit's "credit payment is due today. Statement amount: …" prints no due date: its
   template has `due_on_receipt`, so the due date is the day the SMS arrived, and Wio credit
   accounts close at month end (`cycle_close_day = 31`): the 1st's SMS makes the statement of
   the month that just ended, which anchors what Wio Credit owes.
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

Ingest rejects a statement dated more than 31 days ahead (`22023`, a misread year). Parse claims
are idempotent: `begin_document_parse` marks a `queued`/`parsing` document `parsing` and returns
its context, but answers `{skip: 'parsed'|'failed'}` for a duplicate or stale queue message;
`fail_document` never flips a `parsed` document back; `resubmit_document` re-queues a failed PDF
that is uploaded again (otherwise the upload is a plain duplicate).

**Document timeline.** Every step appends a `document_events` row the apps follow over Realtime
(`statements-upload` returns each file's `doc_code`; subscribe with `doc_code=eq.<code>` and read
the earlier rows once):

| Stage | Written by | Message / detail |
|---|---|---|
| `received`, `stored`, `queued` | `storeDocument` (statements-upload, gmail-push, outlook-poll) via `log_document_event` | file name and size; source |
| `duplicate` | `storeDocument` for an already-stored PDF | the earlier upload's `parse_status` |
| `parsing` | `begin_document_parse` | attempt number |
| `parsed` | the worker, after the parser answers | bank, document kind, statement and line counts, parser warnings (generic notes, never line text) |
| `ingested` | `ingest_parsed_document` | statements; lines new / unchanged / withdrawn; transactions created / matched; lines held for review; cards added |
| `failed` | `fail_document(permanent)` | a sentence per error code (`private.document_failure_message`: wrong PDF password, unsupported layout, …); `detail.error_code` |
| `retry` | `fail_document(transient)`, `resubmit_document`, `requeue_documents` | reason |

Messages never carry passwords, PDF text, statement-line text or SMS bodies (the raw parser or
database error stays in `documents.parse_error`). A failed log write never fails an upload or a
parse. `created_at` defaults to `clock_timestamp()` so events of one transaction keep their order.

### SMS path

`ingest_sms(profile, [{client_msg_id, received_at, sender, body}])` validates, stores and
processes **each message on its own**, so one bad message never fails the batch. Every message
gets its own result status: the `process_sms` outcome (for example `unknown_card`, `held`,
`ignored`, `unparsed`); `duplicate_delivery` for a `client_msg_id` already stored;
`rejected_otp` (defence in depth: OTPs are dropped on the device, the only filtering the phone
does; both sides use one pattern, `private.sms_otp_pattern()` = `SMSCapture.otpPatternSource`,
pinned by a shared fixture); `invalid` with a `reason`
when the shape is wrong (missing `client_msg_id`, empty or over-long body, bad `received_at`);
or `failed` with `reason = error:<sqlstate>` when processing raised (the message is kept with
`parse_status = failed`). Clients (the iOS outbox) park only that message. `process_sms`:

0. A sender starting `AD-` (the TDRA prefix UAE senders must put on adverts; no alert uses it)
   is stored `ignored` with `ignore_reason = 'promotion'`, before any template or LLM call.
1. `match_sms_template` takes the first active template by `priority` whose sender and body
   regex match. A template whose date fields don't form a real date (`31/02/26`) does not
   apply; it never raises.
   - **No template matches:** the message is `unparsed` and an `sms_fallback` job is enqueued.
   - **`other` / `debit_card`:** the message is `ignored`. Approval prompts, due reminders,
     logins and the debit-card and account alerts no template reads yet are seeded at priority
     900+ so they never reach the LLM.
   - **`debit_purchase` / `account_credit` / `account_debit`** (Phase 2b): bank-account alerts.
     They resolve to a bank account, never a card account: the debit card on it, else the
     account the alert names (`account_ref` digits matched from the right), else, when the alert
     names none, the bank's one active bank account. A debit card seen for the first time is
     registered on that account (unless a card of that bank already has its digits). No account:
     `ignored` with `ignore_reason = 'no_bank_account'`, re-run when `create_bank_account` adds
     one (`private.reprocess_bank_sms`). The balance an alert prints becomes a
     `balance_checkpoints` row (`source = 'sms'`). They become `purchase`, `transfer_in` and
     `transfer_out` transactions, `posted` straight away (a bank account has no statement to
     wait for). A debit purchase counts as spend; transfers don't (`v_spend`'s kind list).
   - **`declined`:** stored and ignored.
2. The template's date and time give `event_at`, otherwise `received_at`; a template date more
   than 7 days from `received_at` is a DD/MM misread and falls back to `received_at`
   (`parsed_fields.event_at_rejected`). The card is resolved by bank + last4. A message that
   names the card only by its first six digits (template field `first6`, the BIN: EIB's
   "starting with 529205") goes to the account of the cards whose `cards.first6` match, else
   to the one account earlier messages with those digits were bound to by an `unknown_card`
   review; it never registers a card. When there is neither, the bank's single active account
   is used.
   - **Unknown card:** an `unknown_card` review opens. Resolving it registers the card and
     re-processes every message waiting on it. A statement that registers the card does the
     same at the end of `ingest_parsed_document` (`private.reprocess_waiting_sms`).
3. `match_sms` runs for purchase, preauth, refund, reversal and payment messages, and for the
   three bank-account kinds; its step 1 drops a repeat of the same alert for all of them.

Adding a live template, activating one, or changing an active one's pattern, priority or scope
re-runs the unparsed/failed messages its sender pattern (and scope) reaches, newest first, 500 at
most (`trg_sms_templates_reprocess`). A rename or deactivation re-runs nothing. A new bank format
needs an INSERT, not a deploy.

### Wallet path

Wio sends app notifications rather than SMS for most purchases, and a shortcut cannot read
another app's notifications. The Shortcuts **Transaction** automation fires on each tap-to-pay
payment with the amount, merchant and the card's display name (no card number); the iOS
"Log Card Payment" intent sends them to
`ingest_wallet_transactions(profile, [{client_msg_id, occurred_at, amount, currency, merchant, pass_name}])`
(owner only, at most 200 items; `amount` is a decimal string > 0, `currency` three capitals,
`merchant` 1–200 and `pass_name` 1–64 characters). Each item becomes an `sms_messages` row with
`source = 'wallet'`, sender `Wallet`, the synthetic body `<CUR> <amount> at <merchant> (<pass name>)`
(so the SMS screens show it unchanged) and the submitted fields in `parsed_fields`. Each event
is a separate tap: a redelivery is caught by `client_msg_id`, and `match_sms`'s duplicate-alert
step (same `body_hash`, or near-identical text within 180 s) never pairs two Wallet rows, so two
identical payments minutes apart are two transactions. Results use the SMS statuses, with `invalid` reasons `invalid_amount`,
`invalid_currency`, `invalid_merchant`, `invalid_pass_name`, `invalid_occurred_at`,
`invalid_client_msg_id` and `not_an_object`.

`process_sms` sends Wallet rows down their own branch: the card is the one whose `wallet_name`
equals the pass name ignoring case, the row becomes a parsed `purchase` dated at `occurred_at`,
and no template is consulted. With no such card an `unknown_card` review opens with candidates
`[{"wallet_name": …}]`; setting that name on a card (trigger `cards_wallet_name_reprocess`)
re-processes the waiting rows and resolves their reviews (`{"auto": "card_registered"}`). The
review's register-card action needs a card number, so for a Wallet row it fails with 22023.

A bank SMS and a Wallet event for the same purchase carry different merchant texts, and
`match_sms` never links two alerts. So before `match_sms`, any parsed purchase alert first looks
for its twin from the **other** source: same account, amount and currency, `event_at` within 30
minutes, on a transaction with no evidence from this alert's source yet (nearest first, so two
same-amount purchases pair one to one). It joins that transaction as `duplicate` evidence
(status `duplicate`). Either order works, and the statement line later posts the one
transaction. Profiles without Wallet rows are unaffected.

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

**FX** (`private.estimate_fx(profile, currency, bank)`, used for pending SMS and lines without an
AED amount). Sources are tried in order:
1. That bank's most recent current statement `fx_rate` for the currency on this profile, from a
   `purchase`, `refund` or `cash_advance` line only (a fee row such as FAB's VAT can carry a
   foreign amount that is not a conversion). It includes the card's real markup. Another bank's
   rate is never used.
2. The AED/USD peg, 3.6725, else `public.fx_rates` (the daily mid rate from the `fx-rates`
   function), × (1 + the bank's markup in `private.bank_fx_fees`).

After each FX update, pending SMS transactions are re-estimated. Estimates stay
`amount_aed_is_estimate = true`, with the rate used in `fx_rate`, until a statement posts the
real amount.

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
- `ledger-llm-enqueue` (18:00 UTC nightly) batches uncovered merchants in groups of 100 into
  `llm_categorize`. After a category-set change, an existing suggestion is re-asked only if its
  category was archived or edited after the suggestion, or its confidence is below 0.8. Merchants in
  `merchant_category_skips` are left out: `declined` until the category set changes,
  `rejected` for good.

**LLM.** (Term sheets the user uploads for a structured note go to `TERMSHEET_LLM_MODEL` through `termsheet-extract`; nothing else of a document is ever sent.) Claude Haiku (`LLM_MODEL`, default `claude-haiku-5-5`) receives only merchant names, up to
3 distinct example descriptions per merchant and the category list, keyed by short refs (`m1`, `c1`)
that the worker maps back to codes. It never sees amounts or PDFs.
Suggestions below 0.5 confidence are dropped and never override a manual merchant choice. When
`ANTHROPIC_API_KEY` is unset, the worker leaves the LLM queues alone and warns once.

**Other pieces:**
- **Rule preview.** `preview_rule` reports "this rule would change N transactions" without saving,
  using `recategorize`'s full tie-break; `p_rule_code` leaves out the rule being edited.
- **Batch jobs** (`nightly`, `enqueue_llm_categorize`, `recategorize_stale`,
  `reestimate_pending_fx`) catch errors per profile (per transaction for FX) and log them to
  `private.job_errors` (30 days); `ops_health.job_errors_24h` counts them.
- **Seeding.** Default categories and rules (from the legacy `category_rules.yaml`) are copied
  into a profile once, by `create_profile` / `seed_profile_defaults`, with their `priority`.
- **Bank profit credits net off the charge.** SIB's WAKALA PROFIT and BONUS credits are Bank Fees
  & Interest (a `fee` category), not Cashback (`income`), so as refunds they reduce the same-day
  MURABAHA PROFIT charge in `v_spend`. The SIB BONUS rule is bank-scoped at priority 90; other
  banks' BONUS credits stay Cashback.

---

### Private merchant masks

The database owner can make chosen transactions appear under a generic merchant name in every
app, for existing and future data. Configuration lives only in `private.merchant_masks`
(`pattern` a case-insensitive POSIX regex, `replacement_merchant_name`, optional
`replacement_category_name`, `active`): no RPC, view, policy or UI reads or edits it, client
roles cannot reach `private`, and RLS without policies keeps even the service role out. The
repository holds no real pattern (tests use a fake token).

- **At the source.** BEFORE triggers mask `statement_lines` (description_raw, description and the
  matching strings of `raw`), `sms_messages` (the template's merchant as written in the body,
  any other matching word, `merchant_raw`, `description`, `parsed_fields.merchant`) and, as a
  safety net, `transactions.description`. A new `merchants` row whose key or name matches
  becomes the mask's generic merchant (`merchant_key(replacement)`), so `resolve_merchant` lands
  there. Transactions derive text and merchant from evidence, so they follow.
- **Evidence identity is unchanged.** This is the one exception to "statement lines are never
  edited": only their text is replaced. `line_key` (hashed from the original text at ingest)
  and SMS `body_hash` stay, so a re-parse of the same statement finds every line unchanged,
  adds nothing and unmasks nothing; SMS dedup still works.
- **Existing data.** `private.apply_merchant_masks(p_profile_code default null)` (service role or
  the owner) re-masks lines and SMS, refreshes their transactions, renames matching global
  merchant rows and aliases to their own code, and masks insight titles and bodies. An AFTER
  trigger on `private.merchant_masks` runs it whenever a mask is inserted or changed.
  Deactivating a mask does not unmask anything.
- **Originals** are kept for the owner only in `private.masked_originals(table_name, row_code,
  column_name, profile_code, mask_code, original)`; the first original is never overwritten.
- **Category.** With `replacement_category_name`, each affected profile gets that category (found
  by name or created as `spend`) as a merchant-level **manual** choice on the generic merchant
  (`merchant_profile_category`). It outranks rules and LLM suggestions; a transaction's own
  manual category still wins, and an owner's later merchant-level choice is kept (only an LLM
  row is replaced).
- Every client surface reads the masked rows: `v_transactions` and its search, evidence (lines,
  SMS), `statement_detail`, `spend_breakdown` and the other analytics, insights, recurring,
  merchant search and leaderboards, exports, and the LLM inputs. Not rewritten: `sms_templates.examples`
  (not client-readable) and user-typed `notes`.

## 6. Analytics and insights

There is **one definition of spend**: `public.v_spend` (`security_invoker`). It counts debit
purchases, fees, interest and cash advances, minus refunds. It excludes payments, transfers
in and out, transfer, ignore, income, saving and support categories, void and orphaned
transactions, and anything marked `exclude_from_spend`. Each row carries `instrument`
(`credit_card` / `debit_card`, from its account); `spend_series` and `spend_breakdown` take
`p_instruments` (null = both). Buckets use `txn_date`, a Dubai date. Every analytics RPC builds
on it. Clients render results and never re-derive money.

**Cash position** (Phase 2d) is `cash_position(profile)`: every active bank account with its `v_bank_balances` balance, as-of, source and staleness, the AED total and whether it is complete; Overview's Cash tile and the Accounts lists render it. `filter_meta` lists bank accounts too (cards first, with `kind` and `account_ref`).

**Cash flow** (Phase 2c) is `public.v_cash_flow`: every row of `v_spend` as `spend`, plus each
bank-account transfer by flow: `income` (filed under an income category such as Salary),
`money_in`, `internal_in`/`internal_out` (a Transfers category), `card_repayment` (paired with a
card payment through `card_transfers`: same AED amount within 3 days, so paying a card from the
bank counts once), `support`, `saving`, `spend_transfer` (a transfer filed under a spend or fee
category, such as rent) and `money_out`. `cash_flow(profile, from, to)` sums them per month and
adds `net` = money in − spend − spend by transfer − support − saving − unfiled out; card
repayments and internal moves are settlement and never change it. Payees are category rules: a
rule on kind, amount and bank ("ADCB transfer out of 23,700 → Family support") files a transfer
that names no counterparty. An unfiled transfer is a move between the ledger's own accounts
(`internal_in`/`internal_out`) when another of its bank accounts has the opposite transfer of the
same AED amount within 3 days, or when a `transfer_notice` SMS (FAB's funds-transfer confirmation)
for it names one of its bank accounts' digits (`parsed_fields.counterparty_ref`). FAB's "Salary
Credit" alert is an `account_credit` described SALARY CREDIT, which a seed rule files under Salary.
**Wio** has a debit account and Wio Credit, a credit line (a `credit_card` account with an
`account_ref`): an alert's account digits may name it, so Wio Credit's "local transfer" paying
another card is a `transfer_out` there, paired with that card's payment through `card_transfers`
and outside cash flow (debt moving between cards). The monthly autopay is a payment on Wio Credit
drawn from the debit account: its template has `pays_from_current_account`, so
`private.add_payment_leg` adds the other leg, a posted `transfer_out` on the bank's one active
current account with `transactions.leg_of_txn_code` = the payment, paired with it in
`card_transfers` (one `card_repayment` in cash flow). The SMS is the payment's evidence (one
active evidence row per SMS), so `refresh_transaction` derives the leg's facts from the payment
and refreshes it with the payment; the leg is void (`payment_gone`) while the payment is not live.
A local transfer's recipient is its description, so it is filed once like a merchant.

**Wealth mode** (`20261020162834`, `tasks/todo.md` §5). The apps have two modes: Spending
(cards, budgets, Activity) and Wealth (bank accounts, cash flow, net worth). `v_transactions`
carries `account_kind` and `in_spending` (every card row, plus purchases, refunds, fees, interest
and cash advances on any account, so a debit-card purchase is still spend); Activity passes
`scope = spending` to `activity_selection` / `activity_summary`, and salary, transfers and
autopay appear only in the account's ledger. `account_ledger(profile, account, from, to)` returns
a bank account's rows newest first with their cash-flow `flow` and `balance_after`, plus opening
and closing balance and money in/out, all in the account's currency. A row's balance is anchored
on the next balance checkpoint at or after it, else the latest one (`private.bank_running_balances`:
balance = checkpoint + running sum − the running sum the checkpoint already includes), so the
bank's printed figures win and the newest row matches `v_bank_balances`; a gap between two
checkpoints shows as a jump, which `balance_drift` reports. `bank_balance_series` gives end-of-day
balances from the account's first evidence on. `net_worth(profile)` is bank cash − card
outstanding (`v_account_balances`) with completeness, and `net_worth_series` reads the month's
last nightly `net_worth_snapshots` row plus today's live figure (holdings join in Phase 1).
`cash_flow` takes an optional account and returns `is_partial` for months that begin before the
ledger's (or account's) first bank evidence, so a month of card spend with no captured income
is not read as a loss.

**Gold and silver** (`20261021070429`, `tasks/todo.md` §6). `metal_prices` keeps every fetch
(global reference data): `gold_24k|22k|21k|18k` (Dubai retail, AED/g), `silver_retail` (Dubai
retail, stored per gram from the per-kilo rate), `gold_spot` / `silver_spot` (USD/oz at the
peg, reference only). `holdings` are a ledger's metals (grams; karat and 24K fineness for gold,
purity for silver; cost in AED, optional), written through `save_holding` / `close_holding`
(owner). `private.holding_values(profile, at)` prices each at an instant: gold is grams × its
karat's rate, a 24K bar of 999.5, 999 or 995 times `private.gold_fineness_factor` (pro rata to
999.9, hardcoded); silver is grams × the retail rate × purity / 0.999. `holdings_valuation`
adds gain vs cost and the 24-hour change; `holdings_value_series` / `metal_price_series` feed
the charts. Net worth is cash + metals − owed, and snapshots carry `holdings_aed`. A price older
than 3 days is stale and makes the metals incomplete. Each holding has a `form` (bar, coin,
jewellery; silver has no jewellery), and the valuation returns `image_path` (`<metal>-<form>.jpg`)
in the public `investment-images` bucket, served like the bank logos (`assets/investments/`).

**Holdings beyond metals, flows, returns** (`20261021093154`, `tasks/todo.md` §7). `holdings.kind`
is `metal`, `plan` (an RL360-style plan), `broker` (an account valued as a whole), `security`
(units × a unit price) or `deposit` (principal, rate, maturity: value = principal × (1 + rate ×
days held / 365), capped at maturity, an estimate; once a bank statement has valued it, its latest
imported value × (1 + rate × days since / 365), to maturity). Each has a currency (AED via the peg or
`fx_rates`, `private.to_aed`). `holding_valuations` are evidence (a value or a unit price as of a
date; the latest on or before a day wins). `holding_flows` are contributions, withdrawals and
income, in the holding's currency and AED, optionally the paying transaction (one flow per
transaction; `removed_at` instead of delete, so an unlinked payment is never re-linked). A
metal's cost and purchase date, or a deposit's principal and start date, are its `holding_cost`
contribution. A holding's `link_pattern` (contains, min 3 characters; or, with `link_exact`, the
whole description, min 2: Wio prints RL360 as "RI") links matching purchases, fees and bank transfers on insert (trigger `transactions_holding_link`)
and when the rule is saved; `link_transaction` links or unlinks by hand. **A linked payment is
saving**: `v_spend` leaves it out and `v_cash_flow` files it as `saving` with `holding_code` (a
linked credit is negative saving); `cash_flow_savings` breaks saving down by holding.
`holding_returns(profile, all|ytd|12m)` gives, per holding and in total, start and end value,
added (contributions − withdrawals), income, growth = end − start − added + income, simple % and
a money-weighted yearly return (`private.xirr`, bisection, from 90 days of history); a holding
with no value at the period's start (this year, 12 months) or with no contribution at all (all
time) is incomplete and stays out of the total. `holdings_value_series` sums the holdings with a
value each day and says whether that is all of them (`complete`). `net_worth`
returns `allocation` by class (cash, gold, silver, plan, broker, security, deposit; owed as a
negative row).

**Structured notes and broker cash** (`20261027124257`). Swissquote (`SWQ`) is a bank; its cash is
a USD `current` account, and every non-AED bank account now counts in cash and net worth
(`v_bank_balances.balance_aed` through `private.to_aed`). `account_entries` are deposits and
withdrawals the user types on such an account (evidence; `add_account_entry` /
`remove_account_entry` post or void the transaction). A **structured note** is a holding of kind
`structured_note` plus its terms: `structured_notes` (ISIN, issuer, currency, denomination, issue
price, strike / final valuation / maturity dates; what was bought: trade date, nominal, price %,
amount, funding account), `structured_note_underlyings` (price-feed symbol, initial level),
`structured_note_observations` (obs and pay date, coupon rate / barrier / memory, autocall trigger
/ amount, all % of initial or of nominal) and `structured_note_payout_branches` (at the final
valuation the highest branch with `min_worst_pct` ≤ the worst performance WP pays
`greatest(0, intercept_pct + slope × WP)` % of nominal, in cash or in shares of the worst
underlying worth that). Every worst-of autocallable held so far fits (Example Bank M Phoenix with a
leveraged put, Example Bank A Phoenix / Sweet / knock-in autocallables, Example Bank B Athena). `security_prices` holds
daily closes (reference data, `record_security_prices`, service). `private.note_evaluate(note,
day)` walks the schedule against the closes on each observation date (or the latest within 4
days; a missing close stops the walk: `awaiting_prices`): memory coupons, the autocall, the final
payout (physical: whole shares per note, the fraction in cash). From the latest closes it gives
each share's performance and its distance to the next autocall, coupon barrier and break-even
(`private.note_break_even`: the lowest WP whose payout returns the price paid), the next
observation and what it would pay today, the payout if it ended today, and the scenarios (called on
each future autocall date with the coupons up to it; the payoff curve 0–150%; best and worst
case). `private.settle_structured_note` records each determined outcome in
`structured_note_events` and, on its payment date, posts it to the funding account: a coupon is a
`transfer_in` "NOTE COUPON <ISIN>" filed under the seeded income category "Investment income" with
an `income` flow; a redemption is a `transfer_in` linked to the holding (a withdrawal: negative
saving); delivered shares become a `security` holding valued from `security_prices`. The note and
its holding close when the last payment is made. The purchase is a `transfer_out` on the trade
date linked to the holding (saving). A transaction made from an account entry or a note is kept
`posted` by `refresh_transaction` (typed evidence) instead of becoming orphaned. A live note is
worth what was invested (decision of 27 Oct). RPCs: `create_structured_note` (the termsheet-v1
draft plus the investment, `docs/contracts/termsheet-v1.md`), `cancel_structured_note` (voids its
entries, closes the holding), `structured_notes_summary`, `structured_note_detail` (terms,
schedule, payout, evaluation, events, each share's closes as % of initial); service
`settle_structured_notes`, `price_symbols`. Term sheets live in the private `term-sheets` bucket
at `<profile_code>/<sha256>.pdf`.

There is likewise **one definition of what a card owes**: `public.v_account_balances`
(`security_invoker`). A sum of transactions cannot know the balance carried in before the first
document, so each account is anchored on a balance the bank printed, the latest of:

- `statement`: the latest active statement with a closing balance, plus the live (pending or
  posted) transactions not on it or an earlier statement. Membership, not dates: a purchase dated
  before the close that posts next cycle is on the next statement.
- `balance_migration`: the latest "BALANCE MIGRATION" adjustment of a replacement card (SIB,
  whose histories print no balance). The old card's billed balance moved onto the new one, so the
  balance restarts at 0 that day and every live transaction from it on counts.
- `none`: `outstanding_aed` is null, not a guess.

An SMS statement anchor has no lines to say what it covers, so the activity added to it is by
date (after the statement date, plus charges dated on it that are still pending), not by `stmt_code`.

**Bank accounts** (Phase 2a, `20261020110310`). `accounts.kind` is `credit_card`, `current` or
`savings`. A bank account has an `account_ref` (the digits a bank prints after the mask,
`XXX310001` → `310001`, unique per profile and bank) and never a credit limit or cycle close day
(check constraint). Its balance is `public.v_bank_balances`: the latest `balance_checkpoints` row
(manual through `record_balance` now, read from SMS in 2b) plus the account's live transactions
dated after it, in the account's currency, with `is_stale` after 7 days and null with no
checkpoint. Checkpoints are evidence: never updated, a newer one supersedes. Card-only readers
(`v_account_balances`, `overview`, `filter_meta`, `resolve_review`, the "the bank has one active
account" fallbacks in SMS and statement resolution, and `merge_accounts`) filter
`kind = 'credit_card'`, and `60_bank_accounts.test.sql` lists every function that reads
`accounts`, so a new reader fails until it is classified. Plan: `tasks/todo.md` §3.

**Bank-account statements** (`20261021115816`, `tasks/todo.md` §9). ADCB's consolidated statement
of accounts is parse-v1 `account_statement_pdf`: each statement names its account (`account`:
kind, full number, alert suffix `ref`, IBAN, product). `ingest_parsed_document` resolves it with
`private.resolve_bank_statement_account` (full number, else an `account_ref` the number ends
with, else a new current/savings account; never the card resolver), registers the debit cards
its lines name on it, re-runs the bank's alerts waiting as `no_bank_account`, and then ingests the
statement like any other: lines are evidence, `match_statement_lines` pairs them with the
account's SMS transactions (the statement line becomes the posting evidence), and the rest become
transactions. The closing balance is a `statement` checkpoint as of the end of the period's last
day in Dubai, so `v_bank_balances` anchors on it until a newer SMS balance. `reconcile_statement`
balances a bank account as opening − debits + credits. `statement_cycles` and
`v_statement_payments` are card-only. The payload's `deposits[]` go to
`private.import_statement_deposits` and its `card_summaries[]` to `private.apply_card_summaries`
(credit limit of a known card only).

`overview` carries each account's `outstanding_aed` and anchor, and the profile's
`outstanding` (active accounts), `outstanding_complete` (every account anchored, every AED
amount known) and `outstanding_has_estimate`. Positive is owed; negative is a credit balance.

And **one definition of whether a statement was paid**: `public.v_statement_payments`
(`security_invoker`, statements of kind `statement`). `amount_paid` sums the card repayments
(`kind = 'payment'`, credit, pending or posted, with an AED amount) dated after the statement date
up to and including the account's next statement date (open-ended for the latest one); a payment
on the statement date is already in that statement's balance. `payment_status` is `paid` (the
closing balance is covered, or nothing was owed), `overdue` (the due date has passed, Asia/Dubai,
and the payments so far cover less than the minimum, or nothing was paid when there is no minimum;
a minimum paid late makes it `part_paid`), `part_paid` (something paid, not overdue), `unpaid` (nothing paid, due today or later) or null (no closing balance; history
extracts). `overview` (`accounts[].latest_statement`), `statement_cycles` and `statement_detail`
carry both, `amount_paid` as a decimal string (UX-1r, WEB-36).

Analytics RPCs (security invoker, so RLS applies, except those marked *, which are
SECURITY DEFINER with an explicit member check and filter by profile themselves):

| Group | RPCs |
|---|---|
| Overview and trends | `overview`, `spend_pace`, `spend_series` (grain, group_by, optional `p_top` with an "Other" fold), `spend_breakdown`* |
| Breakdowns | `category_breakdown`, `merchant_leaderboard`, `merchant_context`*, `daily_spend`, `hour_weekday_pattern` |
| Currency and cycles | `fx_spend`, `statement_cycles`, `statement_detail`*, `yoy_compare` |
| Exceptions and metadata | `anomalies`*, `filter_meta` |
| Budgets and recurring | `budget_status`, `recurring_list` |

`overview` (accounts), `statement_cycles` and `filter_meta` (banks) carry each bank's `logo_path`.

`spend_breakdown(profile, from, to, group_by, top_n = 10)` returns monthly spend from `v_spend`
grouped by `category`, `bank` or `merchant`:
`{group_by, total, months: ['YYYY-MM'…], groups: [{key, label, color_token, logo_path, total, share}],
series: [{month, total, values: {<key>: amount}}]}`. The top N groups by total over the whole
range keep their key (`__uncategorized__` / `__unknown__` for none); the rest fold into
`__other__` ("Others"). Every month of the range is listed and every series row carries every
group key, zero-filled. Money is a decimal string; `share` is the group's part of the range
total with 4 decimals, clamped to 0..1 (a group of only refunds can be net negative).
`color_token` is set for categories only, `logo_path` for banks only.

`statement_detail(profile, stmt)` returns one statement with its current lines:
`{statement: {stmt_code, kind, bank_code, account_code, card_last4s, statement_date, period_start,
period_end, due_date, opening_balance, closing_balance, total_debits, total_credits, min_due,
credit_limit, doc_code, recon_status, recon_checks, payment_status, amount_paid}, debits: {count, total, lines}, credits: {…}}`;
a line is `{line_code, txn_code, txn_date, posting_date, description, merchant_name, amount_aed,
amount_original, currency_original, category_code, kind, card_last4}`, ordered by `txn_date`,
`line_no`. `description` is the line as the statement printed it; `merchant_name` and
`category_code` come from the transaction the line evidences.

`merchant_context(profile, merchant)` is the transaction drawer's line about a merchant (MA-4):
`{merchant_code, visit_count, avg_aed, total_6m_aed, first_seen}` from `v_spend`. A visit is a
purchase (a positive `v_spend` row, pending included; refunds are not visits); `avg_aed` is their
average; `total_6m_aed` is net spend (refunds subtracted) dated after the same date 6 months ago
(Asia/Dubai); `first_seen` is the earliest spend date. Money is a decimal string; a merchant
with no spend in the ledger returns zero visits.

`anomalies(profile, from, to)` lists the range's unusually large charges, largest first, each
compared with the 365 days before it (its own day excluded). `reason` is `merchant_outlier` (≥ 5
earlier purchases at the merchant, more than mean + 3 sd and 1.5× the mean), `category_outlier`
(≥ 10 in the category, more than mean + 3 sd; uncategorised spend has no category baseline) or
`new_merchant_large` (the first purchase at a known merchant, at least AED 500 and, when the
category has ≥ 5 earlier purchases, at least 2× their mean). Each row names the charge
(`merchant_code`, `merchant_name`, `category_code`, `category_name`, and the raw `description`)
and says what it was compared with: `baseline_scope` (`merchant`, `category` or null),
`baseline_mean` / `baseline_sd` of that scope, and `times_usual` (amount ÷ `baseline_mean`, whole
from 3×, one decimal below), so a client prints "about 4× your usual Shopping purchase" as is.
An owner's `dismiss_anomaly(profile, txn)` ("This is fine") records the charge in
`anomaly_dismissals` and dismisses its `large_transaction` insight; `anomalies` leaves dismissed
charges out, so the nightly feed doesn't raise them again.

`v_transactions` is the Activity read model. It carries category source, evidence flags
(`has_sms`, `has_statement`; scalar sub-queries on the evidence index, evaluated only for the
rows a page returns), bank and last4.

Activity bulk actions (SECURITY DEFINER, member check, filtered by profile) act on a selection:
either `p_txn_codes` (the ticked rows; another profile's codes match nothing) or `p_filter`, "select
all matching", a jsonb object with the web URL's filter keys (`from`, `to`, `account`, `card`,
`category` with `'none'` for uncategorised, `status`, `source`, `q`), read exactly as
`activity_summary` reads them, through `private.activity_selection`. Exactly one must be given,
so a forgotten argument never means "everything".
- `activity_day_totals(profile, filter, days)`: the Activity date headers (MA-3). For the dates a
  page shows (at most 2000), each day's `{txn_date, txn_count, net_aed, unpriced_count,
  has_estimate}` over the whole filtered set, so a day split across pages reads the same on both;
  net as in `activity_summary`. The page's dates also narrow the filter's `from`/`to`. One call
  per page; days with nothing on them are left out.
- `activity_selection_summary(profile, codes | filter)`: `{txn_count, net_aed, unpriced_count,
  has_estimate, excluded_count}`, net as in `activity_summary` (pending and posted, debits minus
  credits, a decimal string).
- `bulk_update_transactions(profile, patch, codes | filter)` (owner): `patch` sets
  `exclude_from_spend` and/or `manual_category_code` (a category of the profile, or null); returns
  the number of rows changed. Changes are audited like single edits.
- `activity_export(profile, codes | filter)`: a jsonb array in list order (a jsonb value, so
  PostgREST's `max_rows` does not truncate it) of `{txn_code, txn_date, txn_time (Dubai HH:MM),
  description, merchant_name, category_name, bank_code, card_last4, account_nickname, direction,
  amount_original, currency_original, amount_aed, net_aed (debit +, credit −),
  amount_aed_is_estimate, status, source, exclude_from_spend, notes}`, money as decimal strings.
  The web app builds the CSV from it and neutralises cells that start with `= + - @` (formula
  injection); plain decimal numbers pass through.

`overview` compares month-to-date with the same days of last month, never past its last day
(`prev_month_to_date_end`), reports `pending_unpriced_count` (pending foreign charges with no
rate yet, which spend cannot include), and computes utilisation from `greatest(closing_balance, 0)`.
Its pace figures come from `spend_pace(profile, month, today)`: `spend_avg_3m_to_date` is the
previous 3 months' `v_spend` up to the same day of the month, over 3 (`month_to_date_end`: day d
covers days 1..d clamped to each month's length; the viewed month's last day covers whole months,
so 31 Oct covers all of September), and `projected_month_end` is
`spend + (spend_avg_3m − spend_avg_3m_to_date)`, or the run rate `spend / d × days_in_month`
when the 3 months before hold no spend; a past month projects to its spend, a future one to null.
Business dates stay `Asia/Dubai`: `profiles.timezone` and `base_currency` are reserved, not used.

The nightly job `private.nightly()` (22:00 UTC = 02:00 Dubai) runs four steps (and, for the
all-profiles run, purges `document_events` older than 90 days first):
1. Voids released authorisations.
2. Detects recurring charges. A merchant's charges on one day are one billing event (their
   sum). ≥ 3 events (≥ 4 weekly, ≥ 2 yearly) at a weekly, monthly or yearly median gap with
   amount CV below 10%, or a monthly biller with steady gaps (≥ 4 events, 75% of gaps 26–35
   days) at any CV, such as a utility bill that varies.
3. Generates the deterministic, deduplicated insight feed: `category_spike`, `budget_risk`,
   `price_change`, `statement_due`, `uncategorized`, `spend_pace` (month-to-date total ≥ 25%
   and AED 500 above the 3-month same-day average, from day 5), `new_recurring` (a series
   detected in the last 7 days), `large_transaction` (`anomalies` over the last 3 days,
   `data.txn_code`, titled with the merchant name, or the cleaned description when the charge has
   no merchant), `cash_advance` (every cash advance of the last 30 days, with the same-day
   CASH ADVANCE FEE and its VAT, `data.txn_code`, kept 30 days from the withdrawal) and
   `review_backlog` (≥ 10 open reviews). Wealth insights (`private.generate_wealth_insights`):
   `balance_stale` (a bank balance never entered or over 7 days old, keyed on the balance's
   date, retired once current), `balance_drift` (an SMS balance of the last 30 days that differs
   from the previous checkpoint plus the activity between by AED 1 or more: a missed alert),
   `salary_late` (no income credit by three days after the usual day of the last three months'
   largest one, retired once it lands) and `annual_fee` (a card's annual or membership fee, net of
   reversals, above its cashback over 12 months, for 60 days after the fee).
   `private.generate_insights` is a wrapper over `generate_spending_insights` and
   `generate_wealth_insights`: change the generators, never the wrapper.
4. Writes the day's `net_worth_snapshots` row per ledger.

---

## 7. Queues, cron and Vault

| pg_cron job | Schedule (UTC) | Action |
|---|---|---|
| `ledger-worker-kick` | `* * * * *` | `private.kick_worker()` calls the `worker` function, only when a queue has visible messages |
| `ledger-recategorize-sweep` | `17 */3 * * *` | `private.recategorize_stale()` |
| `ledger-fx-rates` | `0 21 * * *` | `fx-rates` function |
| `ledger-metal-prices` | `7 */6 * * *` | `metal-prices` function |
| `ledger-stock-prices` | `30 22 * * 1-6` | `stock-prices` function |
| `ledger-rl360-sync` | `20 2 * * *` | `rl360-sync` function |
| `ledger-nightly` | `0 22 * * *` | `private.nightly()` |
| `ledger-llm-enqueue` | `0 18 * * *` | `private.enqueue_llm_categorize()` |
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
`worker_document_context` / `begin_document_parse` and `worker_mailbox_secret`.
`delete_profile` archives the profile and keeps both kinds.

`email_mailboxes.sync_state` is written through `save_mailbox_sync_state`: a key-wise jsonb merge
under a row lock, so concurrent writers keep each other's keys, and `gmail_history_id`,
`last_synced_at` and `watch_expires_at` never move back.

Realtime publishes `transactions`, `sms_messages`, `documents`, `match_reviews`, `insights` and
`document_events`. RLS applies to every change event.

---

## 8. Auth and RLS

- **Users** sign in with Supabase Auth: an emailed one-time code or a **passkey** (WebAuthn,
  relying party `<web-host>`; the iOS app shares it through Associated
  Domains and the web host's `apple-app-site-association`). There are no sign-in links in
  emails, and no passwords except two: the seeded local demo user (Debug iOS `DevSignIn`) and,
  in production, the App Review demo account, which owns only the synthetic `app-review` ledger
  (`private.create_review_demo`, PRODUCTION §7) and signs in through the iOS app's *Sign in with
  a password*. After a code sign-in, web and iOS offer to add a passkey; "Not now" is
  remembered per user on the device, and Settings manages passkeys. Membership in `profile_members`
  grants access, and a profile can have several owners and viewers.
- **Super admin.** Emails in `private.super_admins` (`h_abbasi97@hotmail.com`), once confirmed
  in Auth, make `authz.is_super_admin()` true: `my_profile_codes()` and the non-owner branch of
  `assert_member` then include every active profile, so the super admin reads every ledger
  (data, members, secret names, tokens) and switches to it as **View only**. Writes still need
  owner membership (`my_owned_profile_codes()`, `assert_member(…, true)`), so another user's
  ledger is read-only in the database, not just in the apps.
- **No self sign-up.** Bank Ledger is private: `[auth] enable_signup = false` locally, and the same
  dashboard setting in production. The email-code request uses `shouldCreateUser: false` (web and iOS), so an
  unknown email gets "Ask the ledger's owner to invite you". A member is added by an owner with
  `add_profile_member` (an existing user is added at once; otherwise a pending invite is
  stored), and the person's Auth user is created by an Auth invite, which works with sign-ups
  off. The web app's Settings → Members does both through the `member-invite` Edge Function
  ("Invite", and "Resend invite" on pending members); elsewhere the invite is sent from the
  Dashboard (Authentication → Users → Invite user) or the admin API. The trigger then claims
  the pending invite once the address is confirmed. The legacy import refuses to adopt a profile key it did not
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
ADCB, FAB, ENBD, SIB and EIB credit-card purchase, refund and decline format in the template
seed, and Wio's says "card" in lower case; a single keyword means each alert fires once.
Bank-account alerts (ADCB "Cr./Dr. transaction … account number", FAB remittances) never say
"Card", so an optional second automation on "Account" catches them (Phase 2b); a message saying
both is sent twice and the server drops the repeat (`match_sms` step 1). Settings → *Set up SMS capture* walks through it
and shows "Last captured" and a "Send test" button. Whether Shortcuts' "contains" is
case-insensitive (the ENBD refund and every Wio payment say "card") still needs a real-device check.

```
Bank SMS → Shortcuts automation → LogBankSMSIntent (openAppWhenRun = false, separate process)
  → SMSCapture.classify (on device: drop OTPs, debit-card / account alerts, no-amount messages)
  → App Group outbox (fresh client_msg_id) → flush via rpc('ingest_sms') to the "SMS go to" ledger
  → per-message result; failures classified as permanent / transient / signed out
```

- **"SMS go to" ledger.** An explicit setting in the App Group, limited to ledgers the user
  owns (default: the first owned one). The App Intent, the share extension and queued PDF
  uploads use it, never the ledger currently on screen.
- **Outbox.** Errors are classified by SQLSTATE / PGRST code, then HTTP status. No connection
  (no mobile data, airplane mode, DNS, timeout: `URLError` connectivity codes) never uses up
  attempts and stops the flush; such a message waits however long it takes, parked only after 7
  days unsent. Other transient ones (5xx, `57014`, `08`/`40`/`53` classes) retry with backoff for
  up to 8 attempts, then park; signed-out never uses up attempts or ages out. A permanent batch error is split until the bad
  message is alone; a `42501` parks that ledger's batch; a per-message `invalid`/`failed`
  status parks only that message. Parked messages are listed in Settings → "Not sent" with
  Retry and Delete, and Shortcut results say why a message waits.
- **Sending without the user** (`OutboxSync`): besides the intent's own attempt and the app
  coming to the foreground, an `NWPathMonitor` sends everything waiting the moment the
  connection returns while the process runs, and whenever something waits the app submits a
  `BGProcessingTask` that requires network connectivity (`com.example.ledger.outbox-send`) plus
  a `BGAppRefreshTask` (`…outbox-refresh`), so iOS sends it after data comes back even with the
  app closed. The message keeps the `received_at` captured when the Shortcut ran.

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
| `credit-card-ledger-apps` | Web app and iPhone app (app, intent, share extension and widgets) | `app` = `web` \| `ios` (plus `target` on iOS) |

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
  - DLQ messages: an error when the DLQ grew since the last run (`newest_age_s < 900`), then a
    daily reminder until `drain_dlq` / `requeue_dlq`
  - documents `parsing` for over 1 h, and the oldest `queued` document older than
    `OPS_QUEUED_DOCUMENT_AGE_S` (3 h; `documents_queued_oldest_age_s`)
  - failed parses
  - unparsed SMS above `OPS_SMS_UNPARSED_THRESHOLD`
  - recon failures (last 7 days)
  - review backlog above `OPS_OPEN_REVIEWS_THRESHOLD` (reviews opened in the last 7 days;
    `open_reviews_total` is all-time)
  - `job_errors_24h`, and per mailbox `mailboxes_stale` (no sync for 2 days),
    `gmail_watch_expiring` (< 24 h) and `mailbox_errors` (`sync_state.last_error`)

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
