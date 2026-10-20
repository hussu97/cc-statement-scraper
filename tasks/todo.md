# Plans

## 1. LLM categorisation: fewer re-asks, short refs, bigger batches (2026-10-09)

Context: prod has made 14 `llm_categorize` calls in total (~$0.02, Haiku 5.5); 234 profile×merchant
pairs reach the LLM. Goal is stability and quality more than spend. No schema change (functions only),
so no `pnpm db:types` drift.

- [x] **Migration `llm_categorize_tuning`** (`20261010001000`, commit 489b152) (`supabase migration new`):
  - [x] `private.enqueue_llm_categorize()`: batches of **100** (was 25).
  - [x] Re-ask rule: an existing `llm` suggestion made against an older category set is re-asked only when
        its category is archived, or was edited after the suggestion (`categories.updated_at >
        merchant_profile_category.updated_at`), or its confidence is < 0.8. Declined merchants are still
        re-asked on any category-set change (a new category may fit). Rejected: never (unchanged).
  - [x] `public.worker_llm_context`: examples are up to 3 **distinct** descriptions (distinct before
        limit; today `limit 3` then `distinct` often yields one), skipping ones equal to the name.
- [x] **Worker** (`supabase/functions/_shared/llm.ts`, `worker/llm_jobs.ts`):
  - [x] Prompt and schema use short refs `m1…mN` / `c1…cN` instead of 30-char codes; enums list the refs.
        `validateSuggestions` maps refs back to codes (unknown ref → dropped, as today).
  - [x] `processLlmCategorize`: accept up to 100 merchants (`slice(0, 100)`).
  - [x] Keep `effort: "low"`; leave thinking as is (optional follow-up: `thinking: disabled` after a
        quality check on a sample).
- [x] **Tests**: deno (`_tests/llm_jobs_test.ts`): ref round-trip, unknown/duplicate refs, 100-merchant
      batch. pgTAP: batch size, re-ask predicate (confident+unchanged → skipped; archived/edited/low
      confidence → queued), distinct examples.
- [x] **Verify**: `supabase db reset && supabase test db`; `cd supabase/functions && deno test -A .`;
      run the worker locally (`curl -s http://127.0.0.1:54321/functions/v1/worker` with `{"sync":true}`)
      against seed data and inspect `merchant_profile_category`; `pnpm check`.
- [x] **Docs**: CHANGELOG (Backend). ARCHITECTURE only if it states the batch size.
- [ ] **Deploy**: merge to `main` deploys the migration + `worker`; ask first (CLAUDE.md §11.2).

## 2. Category taxonomy v2 (`20261010001100`, commit c93956e)

Audit 2026-10-09 (prod, read-only). Top two categories per profile take 44% (P1: Shopping 27% +
Dining 18%) and 42% (P2: Transport 26% + Dining 17%); Utilities is 11–14% and mixes bills with
household services. Seed rules also misfile: `UBER` → Travel (rides and Uber Eats), `EMIRATES` → Travel
(Emirates Hospital, Emirates Leisure Retail, Emirates Fast Food), fees under Govt/Subscription/Investment.

Proposed spend categories (16 → 25; Cashback and Card Repayment unchanged):

| Today | Proposed |
|---|---|
| Dining | Restaurants & cafés · Food delivery |
| Shopping | Online marketplaces · Fashion · Home & furniture · Beauty & personal care · BNPL instalments |
| Transport | Rides & taxis · Fuel, charging & parking |
| Travel | Flights · Hotels & holidays |
| Utilities | Telecom & internet · Electricity, water & gas · Home services |
| Entertainment | Entertainment & activities (salons/spa → Beauty; Udemy → Education) |
| Fines/Govt Services | Government & fines (fees out) |
| Forex Charge + fees scattered elsewhere | Bank fees & interest |
| Medicine | Health & medical |
| Grocery, Subscription, Apple in-app purchase, Insurance, Investment, Donation, Fraud | unchanged |

Decided: both profiles; Forex Charge stays separate; BNPL and Education are their own categories;
Home & Furniture / Home Services / Hotels split dropped (too small). Al Jamea tus Saifiyah → Education.

- [x] Content migration (guarded, CLAUDE.md §1.9): new seed categories; per profile insert when absent;
      re-point/split seed rules only where they still hold the seeded pattern; fix the `UBER` /
      `EMIRATES` / fee rules; drop `llm` suggestions in split categories so the nightly job re-asks them
      (manual choices untouched). Depends on plan 1's re-ask rule.
- [x] pgTAP for the rule fixes; CHANGELOG; verify category shares on a prod-shaped local dump.
- [ ] Later (optional): roll analytics up by `parent_code` so charts can show ~10 groups with drill-down.

### Review (2026-10-09)
- Verified: deno 153 pass; pgTAP 883 pass from a fresh reset; worker run locally against Haiku 5.5
  (9 seed merchants, refs mapped back correctly); taxonomy replayed on 3,136 production descriptions
  (local copy of the old rules reproduced prod for 585/588 descriptions, then every move inspected).
- Backfill instead of tonight's Haiku run: 249 merchants on the LLM path classified in-session
  (59 moved, 17 left declined), applied via `apply_llm_suggestions` with the v2 category-set hash so
  `enqueue_llm_categorize` finds nothing. Script kept out of git (merchant codes).
- [ ] Push to main (deploys both migrations + worker), then run the backfill, then verify
      `needed_now = 0` and the new category shares in prod.

## 3. Phase 2: bank accounts, balances, debit cards and cash flow (2026-10-20) — approved; 2a built

Goal: a ledger can hold current/savings accounts next to its cards, know each account's balance,
capture debit-card and account SMS, and answer "where did the salary go" without letting transfers
pollute spend. Touches the schema, the SMS contract and every account reader, so this plan needs the
user's go-ahead before code (CLAUDE.md §12.1).

**What exists today** (read-only checks on prod, 20 Oct):
- `accounts.kind` allows only `credit_card`. 37 migrations read `accounts`, and none filters by kind:
  every reader assumes an account is a card (limit, cycle close day, statements, utilisation).
- ADCB and FAB templates already parse debit-card purchases, account Cr./Dr. alerts, outward
  remittances and funds transfers (amount, merchant, available balance), then mark them `ignored`
  (`process_sms`, DB-34). ENBD, SIB, EIB and Wio have none; Liv and Mashreq have no templates at all.
- No debit or account SMS has ever reached production: the iOS automation fires only on messages
  containing "Card", and account alerts don't say "Card". Nothing to backfill; capture starts fresh.
- `sms_messages.available_limit` already stores an alert's balance figure.
- `card_transfers` links any debit transaction to any credit transaction (matched by
  `private.link_card_transfer`), so it can match bank→card repayments too.
- Status is derived from evidence: SMS-only is `pending` until a statement line posts it. Bank
  accounts have no statements yet, so that rule has to change for them.

### Decisions (approved 2026-10-20: 1–3 as recommended; 4 still open)
1. **Debit-card purchases count as spend**, tagged by instrument, with credit/debit/both filters.
   They're real purchases; leaving them out undercounts lifestyle spend. The alternative is a separate
   "debit spend" figure outside `v_spend`, which breaks "one definition of spend" (§1.12).
2. **Money to family is a flow of its own** (category kind `support`), shown in cash flow and never
   in spend. Same for investing (kind `saving`).
3. **Fixed deposits wait for Phase 1 (holdings).** Phase 2 covers current and savings accounts only;
   a deposit is a holding with a maturity date, not a transacting account.
4. **Which bank receives the salary?** That account goes first: its debit and account templates,
   and the first automation.

### 2a. Accounts and balances
- [x] Migration: `accounts.kind` check adds `current`, `savings`. New `accounts.account_ref` (the
      masked suffix banks print, e.g. `810001`), unique per (profile, bank, ref). The card-only columns
      stay null for these, with a check that `credit_limit`/`cycle_close_day` are null unless
      `kind = 'credit_card'`.
- [x] **Audit every `accounts` reader** (the 37 migrations' current definitions, web `src/data/`,
      LedgerKit). Card-only readers (utilisation, statements, `v_account_balances`, card budgets,
      `statement_cycles`, card names) filter `kind = 'credit_card'`. A pgTAP guard fails if a new
      bank account appears in any card-only RPC.
- [x] `balance_checkpoints` (account, `as_of timestamptz`, `balance numeric(14,2)`, source
      `sms`/`manual`, `sms_code` nullable). Immutable evidence, RLS like every table.
- [x] `v_bank_balances` (security_invoker): latest checkpoint plus account transactions after
      `as_of`; returns `balance_aed`, `as_of` and `is_stale` (older than 7 days).
- [x] RPCs: `create_bank_account(profile, bank, kind, ref, nickname)` and
      `record_balance(account, balance, as_of)`, both owner-only via `private.assert_member`.
      Update `11_privileges.test.sql`.
- [x] Review (2026-10-20, commit 34ce2f9): pgTAP 1,624 pass from a fresh reset on an isolated stack
      (`60_bank_accounts`, new cases in `08`/`11`); the 26 functions reading `accounts` are listed
      and classified; web 516 tests, tsc and build; LedgerKit 556; iOS app builds. Web click-through
      with an ADCB current and a FAB savings account beside the ADCB and FAB cards: Overview, Cards,
      the comparison, Activity filters and card names show the cards only. No screens for bank
      accounts yet (2d). Not merged or deployed.

### 2b. Capture debit-card and account SMS
- [x] `process_sms`: `debit_card` alerts stop being ignored once they resolve to a bank account, by
      debit-card last4 (cards on a bank account) or by `account_ref`. Unresolved ones stay ignored
      with a `match_reviews` row, the same as an unknown credit card today.
- [x] Split `msg_kind` `debit_card` into `debit_purchase`, `account_credit`, `account_debit` and
      `transfer_out` so each maps to a transaction kind. Transaction kinds add `transfer_in`,
      `transfer_out`, `atm_withdrawal`. Content migration re-points the ADCB/FAB templates only
      while they still hold their seeded `msg_kind` (§1.9).
- [x] Templates capture `balance` (into a checkpoint) and `counterparty_ref` (the masked IBAN, account
      or card a transfer went to). Add the field to the parse contract and the template tests.
- [x] `refresh_transaction`: on a non-card account, SMS evidence is final, so `posted`.
- [x] iOS: a second automation keyword ("account") with the same action, plus a guide step. A
      message holding both words fires both automations, with two `client_msg_id`s; only the card
      matcher treats a same-`body_hash` twin as a duplicate today, so ingest must drop it for every
      kind (pgTAP). New banks' formats come through the existing
      unparsed → proposed-format → Review flow (PAR-14).
- [x] pgTAP for each template example and for account resolution; LedgerKit test for the guide text.
- [x] Review (2026-10-20): built with three kinds, not four: `account_debit` covers transfers and
      remittances, and `atm_withdrawal` waits for a real ATM alert to template. Counterparty
      capture moves to 2c with payees (FAB's funds-transfer notice, which names the payee, stays
      ignored for now). Also added: FAB inward remittance (the likely salary format at FAB), and
      `create_bank_account` re-runs waiting alerts. pgTAP 1,658 on an isolated stack (`61_bank_sms`,
      updated `04`, `38`, `60`), deno 156, web 516, LedgerKit 557. Web click-through on the demo
      ledger: a salary credit, a transfer and a FAB debit purchase show in Activity (transfers
      Uncategorised until 2c); Overview spend rose by the debit purchase only; Uncategorised count
      unchanged. Not merged or deployed.

### 2c. Classification and cash flow
- [x] `categories.kind` adds `saving` and `support`. `v_spend` excludes them (as it does transfer,
      ignore and income) and gains an `instrument` column: `credit_card` / `debit_card`.
- [x] `payees`: a `counterparty_ref` mapped to a name and a category ("…4301 → Parents → Family
      support"). Set from a transfer row in Activity, then applied by categorisation like a merchant.
- [x] Repayments: a `transfer_out` whose `counterparty_ref` is one of the ledger's own card last4s, or
      whose amount and date match a card payment, is linked through `card_transfers` and counts once,
      as a move. `link_card_transfer` learns the bank side.
- [x] `v_cash_flow` and `cash_flow(profile, month)`: income, spend (by instrument), support,
      saving, card repayments, cash withdrawals, internal moves, net. Computed in SQL (§2.2).
- [x] Analytics RPCs take an optional `p_instruments`; defaults keep today's numbers until the web
      and iOS filters ship, so nothing shifts silently.
- [x] Review (2026-10-20): payees are category rules (kind, amount, bank conditions already exist),
      not a new table: most bank alerts name no counterparty, so a description-keyed payee table
      would sit empty. A transfer filed under a spend category is `spend_transfer` in cash flow
      but not in `v_spend` (rent by transfer is not on the spend charts yet). Instrument filter
      ships on web Trends; iOS gets it with the 2d screens. pgTAP 1,667 twice on an isolated stack
      (`62_cash_flow`, updated `01`, `11`, `25`; `31`'s same-millisecond ordering race fixed),
      web 518, LedgerKit 557. Click-through: Trends → Debit shows only the debit purchase; an
      invalid `?range=` no longer crashes Insights (pre-existing; fixed as the TanStack lesson
      says). Not merged or deployed.

### 2d. Screens and insights
- [ ] Web and iOS: an Accounts section (balance, "as of", update balance), a Cash flow screen for the
      month, an instrument filter on spend, and Overview's cash tile. Loading, empty and failed
      states for each (§4.3).
- [ ] Insights: salary not received by the usual day, a stale balance, a balance that disagrees with
      the computed one (missed SMS), cash withdrawals, and support/saving below the plan (once
      Phase 3 adds plans).

### Verify and ship
- [ ] `supabase db reset && supabase test db`, `pnpm db:types`, `deno test`, web tests, `swift test`,
      `pnpm check`. Run it: local stack, a fixture ADCB account SMS through `ingest-sms`, then look at
      Accounts and Cash flow in the browser and the simulator.
- [ ] Docs: ARCHITECTURE (accounts, balances, SMS kinds, cash flow), README (screens, automation),
      `docs/contracts` if the SMS fields change, CHANGELOG.
- [ ] One PR per sub-phase (2a, then 2b and 2c, then 2d). Each merge to main deploys
      migrations and functions, so ask before each one.

**Risks.** The account-reader audit is the big one: a missed card-only reader shows a bank account
with "0% utilisation" or a statement cycle. The guard test catches new readers but not misreads, so
2a ships alone and gets a full click-through. A second automation keyword double-fires on a message
that contains both words; 2b's same-text dedupe must land with it.
