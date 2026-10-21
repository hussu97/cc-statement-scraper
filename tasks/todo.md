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

## 3. Phase 2: bank accounts, balances, debit cards and cash flow (2026-10-20) — shipped (main 603ad56, f1680e9)

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
- [x] Web and iOS: an Accounts section (balance, "as of", update balance), a Cash flow screen for the
      month, an instrument filter on spend, and Overview's cash tile. Loading, empty and failed
      states for each (§4.3).
- [ ] Insights: salary not received by the usual day, a stale balance, a balance that disagrees with
      the computed one (missed SMS), cash withdrawals, and support/saving below the plan (once
      Phase 3 adds plans).
- [x] Review (2026-10-20): built by two parallel agents on the `cash_position` / `cash_flow` contract;
      re-checked here: web 538 tests, tsc, lint, build; LedgerKit 577; app build; pgTAP 1,669 on the
      isolated stack. Both ran it against demo data (balances updated, accounts added, duplicate and
      bad-input errors, light/dark, phone width; iOS in the simulator). Not checked: the viewer role
      and the Moves group with real repayments. Insights (salary late, stale balance, drift) are
      still open: not asked for in this round. Known: months before account alerts were captured
      show a negative net (card spend, no income). Not merged or deployed.

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

## 4. Backlog: from card tracker to complete money picture (2026-10-20)

What is left of the plan from the 2026-10-20 audit ("Taking Bank Ledger from card tracker to money
picture"). Phase 2 (bank accounts, balances, debit-card and account SMS, cash flow, screens) and
the Wio/FAB salary formats are shipped. Each phase below changes the schema, so it gets a written
plan and the user's go-ahead before code (CLAUDE.md §12.1), and ships on its own.

### Phase 1: net worth (holdings, valuations, flows)
Goal: one net-worth figure per ledger, over time, with returns that separate deposits from growth.
- [ ] `holdings`: name, institution, asset class (cash, fixed_deposit, equity, bond, gold, silver,
      insurance_wrapper, property, other), currency, quantity + unit (g, kg, units), optional
      `account_code` (a fixed deposit or broker cash), maturity date and rate for deposits.
- [ ] `holding_valuations`: dated value in its own currency plus AED (evidence, never edited;
      source manual / price_feed / import). This is the series behind a net-worth chart.
- [ ] `holding_flows`: contributions, withdrawals, income (dividends, profit). Return = value −
      net contributions; a yearly money-weighted return (XIRR) per holding, computed in SQL.
- [ ] Prices: gold and silver per gram from a daily pg_cron job (Edge Function, a metals price
      API; new secret → PRODUCTION §2.5); USD at the 3.6725 peg; broker values by monthly CSV
      import (IBKR flex query, Swissquote, Sarwa) or manual entry.
- [ ] One-off import of the user's investment sheet (17 holdings: gold 1 kg and 200 g, silver
      8 kg, Talabat IPO, Nexus Insurance, Swissquote, RL360, Sarwa, IBKR, ADCB / Wio / Mashreq Neo
      fixed deposits, bank cash), with the sheet's USD cost/value columns as native currency.
- [ ] Fixed deposits move here from Phase 2 (decision 3): a holding with maturity and rate,
      linked to its bank account.
- [ ] `net_worth(profile)` and a monthly series: holdings + bank balances (`v_bank_balances`) −
      card outstanding (`v_account_balances`), with completeness and staleness like
      `cash_position`.
- [ ] Contributions link to cash flow: a `saving` transfer or card purchase (RL360 7,400 a month
      on the Wio card) can be matched to a holding's contribution, so saving shows where it went.
- [ ] Screens (web + iOS): Net worth page (total, allocation by class, each holding with value,
      gain, yearly return, as-of), Update value / Add holding, a Net worth tile on Overview.
- [ ] Tests: pgTAP for valuations, XIRR, net worth; LedgerKit/web pure-logic tests; RLS and
      privileges matrix for the three new tables.

### Phase 3: plan, goals and the monthly review
Goal: say what the money should do each month, and show whether it did.
- [ ] Monthly plan per ledger: income → commitments (family support, long-term fund) → lifestyle
      cap → the rest to named goals. Plan adherence computed against `cash_flow` per month.
- [ ] `goals`: emergency fund (N months of outflow), a gold target, a cash buffer before a deposit
      matures, any amount by a date; each with progress and the monthly amount needed, in SQL.
- [ ] Monthly review page (web) and push (iOS): the cash-flow statement, change in net worth
      (saved vs market move), plan adherence, the three biggest changes. Numbers from the server;
      an LLM writes only the summary sentence, never a figure.
- [ ] Plan/goal editor screens on web and iOS; goal cards on Overview.

### Insights still to add ("Worth a look")
- [ ] Salary not received by its usual day (from the Salary category's history).
- [ ] Bank balance stale (over 7 days) or drifting: the printed SMS balance disagrees with
      checkpoint + activity (a missed alert).
- [ ] Card annual fee against the rewards that card earned in the year.
- [ ] Each card's FX markup against a reference rate; suggest the cheapest card abroad.
- [ ] Subscription creep: a recurring biller's quarter-on-quarter rise (Apple billing).
- [ ] Idle cash above the plan's buffer (needs Phase 3's plan).
- [ ] Support or saving below the plan (needs Phase 3).

### Phase 2 leftovers
- [x] Wio Credit statement anchor (`20261020170933`): the "credit payment is due today.
      Statement amount" SMS is a `statement_summary` with `due_on_receipt` (due = the day it
      arrives); Wio credit accounts close at month end (`cycle_close_day = 31`), so the 1st's SMS
      is the previous month's statement and anchors `v_account_balances`. pgTAP 65.
      Open: a Wio Credit account created later has no close day until it is set (the summary then
      says `cycle_unknown` and is not re-read when the day is set); a card purchase pending on the
      close day counts after the close (the SIB rule), which may not match Wio's 11:59 PM close.
- [x] Wio Credit autopay debit leg (`20261020170933`): templates with `pays_from_current_account`
      add a `transfer_out` on the bank's one active current account (`leg_of_txn_code`, facts
      derived from the payment), paired in `card_transfers` (one `card_repayment`). pgTAP 65.
- [ ] Guides (web + iOS): a third optional automation on "Wio" for the autopay (only noted in
      README so far); ship with the next app release.
- [ ] Rent or bills paid by transfer: a transfer filed under a spend category is `spend_transfer`
      in cash flow but not in `v_spend`, so spend charts miss it. Decide whether `v_spend` counts
      user-filed transfers.
- [ ] `cash_flow` per account (so "Unfiled" can link to the right account when there are several)
      and group subtotals from the server (web/iOS show lines and the server's net only).
- [ ] More bank formats as they arrive (Liv, Mashreq Neo, ENBD/SIB/EIB account alerts): the
      unparsed → proposed format → Review flow handles new ones; add seeds when a real sample
      exists. ATM withdrawals on debit cards (`atm_withdrawal` kind) when a sample exists.
- [ ] Not yet checked by hand: the viewer role on the Cash flow / Cash & accounts screens, and the
      Moves group with real repayments.
- [ ] Months before account alerts were captured show negative net (card spend, no income):
      either start cash flow at the first account alert or mark earlier months as partial.


## 5. Wealth mode: bank accounts, their ledgers, cash flow and net worth (2026-10-20)

Ask (20 Oct): show debit accounts and their transactions cleanly, apart from the credit-card
spend that budgets track, because the accounts are the user's real financial value.

### Decisions (user, 20 Oct)
1. **Two modes, one switcher.** A header dropdown switches between **Spending** (today's app:
   Overview, Activity, Insights, Budgets, Cards) and **Wealth** (bank accounts, cash flow, net
   worth; investments and goals later). Shared screens (Review, Rules, Settings with cards and
   statements) appear in both. iOS swaps the tab bar per mode.
2. **Debit-card purchases stay in spend and budgets** (Phase 2 decision 1 stands), tagged Debit in
   Activity. Salary, transfers, autopay, support and saving rows leave Spending's Activity and
   live in the account's ledger under Wealth.
3. **No holdings or sheet import now** (Google Sheets is not the way in). Net worth for now is
   bank cash − what the cards owe; holdings join it in Phase 1.

### 5a. Backend
- [x] `v_transactions` gains `account_kind` and `in_spending` (a card row, or a purchase, refund,
      fee, interest or cash advance on any account). Activity's reader (`activity_selection`,
      `activity_summary`) takes `scope = spending`; absent = everything (old app builds).
- [x] `account_ledger(profile, account, from, to)`: the account's rows like a bank statement,
      each with its cash-flow flow and a **running balance** anchored on the nearest balance
      checkpoint (next one after the row, else the latest before), plus opening/closing balance
      and money in/out for the period. Server-side (§2.2).
- [x] `bank_balance_series(profile, account, from, to)`: end-of-day balances for the account
      chart, known from the account's first transaction or checkpoint on.
- [x] `net_worth(profile)`: cash (bank balances) − owed (cards, `v_account_balances`) with
      completeness; `net_worth_snapshots` written nightly; `net_worth_series` = month-end
      snapshots + today's live figure.
- [x] `cash_flow` takes an optional account and flags `is_partial` months (before the ledger,
      or the account, has any bank evidence), so pre-capture months stop reading as losses.
- [x] Insights: `balance_stale` (or never entered), `balance_drift` (an SMS balance disagrees
      with the previous one plus the activity between: a missed alert), `salary_late` (income
      not in by its usual day), `annual_fee` (a card's annual fee above the cashback it earned
      in 12 months). `private.generate_insights` becomes a wrapper over the spending generator
      and a new wealth generator.
- [x] pgTAP for each; privileges matrix; `pnpm db:types`.

### 5b. Web
- [x] Mode switcher at the top of the sidebar (and the mobile header); routes under `/wealth`.
- [x] Wealth overview: net worth hero (cash, owed, net; as-of and completeness), net worth over
      time, accounts (bank) and liabilities (cards owed), this month's cash flow, wealth insights.
- [x] Accounts: list → account page (balance, update balance, balance chart, month in/out,
      ledger with running balance and flow chips; category editing for transfers).
- [x] Cash flow moves to `/wealth/cash-flow` (old path redirects); Unfiled links open the account.
- [x] Spending: Activity uses `scope = spending` and tags debit purchases; Overview's Cash tile
      goes (the switcher is the way across).

### 5c. iOS
- [x] `AppMode` in LedgerKit (persisted), a title menu to switch, tabs per mode: Spending
      (Overview, Activity, Insights, Budgets, Settings), Wealth (Overview, Accounts, Cash flow,
      Settings).
- [x] Wealth overview, account list + account ledger, cash flow; spending Activity scoped.

### 5d. Verify and ship
- [ ] Fresh reset + pgTAP, deno, web tests/build, `swift test`, app build, `pnpm check`; click
      through both modes on web and in the simulator with demo bank data.
- [ ] Docs: ARCHITECTURE (§6 wealth), README (screens), CHANGELOG, lessons if any.
- [ ] PR from `wio-accounts`; merging deploys migrations, functions, web and a TestFlight build.

Left in §4: holdings (Phase 1 proper), goals (Phase 3), FX markup and subscription-creep
insights, Wio Credit SMS statement anchor, Wio autopay's debit leg, rent-by-transfer in spend.

## 6. Gold and silver: prices, holdings and gains in Wealth (2026-10-21)

Ask (21 Oct): fetch the AED price of gold and silver on a Supabase cron so Wealth shows what
the metals are worth and the gain on them.

### Decisions (user, 21 Oct)
1. **Gold at the Dubai retail rate**: the Dubai Jewellery Group's "suggested retail" per-gram
   rates (24K/22K/21K/18K) from dubaicityofgold.com (its `admin-ajax.php?action=sortd_gold_price`
   returns today's rates only, so history is ours). There is no Dubai retail silver rate: silver
   uses spot (gold-api.com, Swissquote as fallback, both free and keyless) at the 3.6725 peg.
2. **Gains vs what was paid**: each holding has an optional total cost in AED; gain = value − cost,
   plus the change since the price 24 hours earlier.
3. **Every 6 hours** (pg_cron `ledger-metal-prices`, `7 */6 * * *`).

### Plan
- [x] `metal_prices` (global reference, like `fx_rates`): quote (`gold_24k|22k|21k|18k`,
      `gold_spot`, `silver_spot`), AED per gram, USD per oz for spot, source, as_of. Every fetch
      is kept (the history behind the charts). `record_metal_prices` (service role) converts
      spot USD/oz to AED/g in SQL at the peg.
- [x] Edge Function `metal-prices` (x-cron-secret, `verify_jwt = false`): DJG retail gold,
      gold-api.com spot with Swissquote fallback; pure parsers with deno tests. A failed source
      is reported to Sentry after the others are stored.
- [x] `holdings` per ledger: name, metal, grams, karat (gold) or purity (silver), cost AED,
      acquired on, notes, status. Owner RPCs `save_holding` / `close_holding`.
- [x] `holdings_valuation(profile)`: each holding's value (grams × the karat's retail rate, or
      grams × purity × silver spot), cost, gain and %, 24-hour change, the price used and its
      age; totals and completeness. `holdings_value_series` and `metal_price_series` for charts.
- [x] Net worth = cash + metals − owed; snapshots gain `holdings_aed`.
- [x] Web + iOS: a Metals section in Wealth (value, gain, today's change, price as-of, a
      90-day chart), Add/Edit holding (owner).
- [x] pgTAP, deno tests, privileges matrix, types; ARCHITECTURE, PRODUCTION (cron, function),
      README, CHANGELOG.
- [x] Later decisions (21 Oct): gold 24K = 999.9 with a hardcoded fineness factor for 999.5 / 999 /
      995 bars; silver at Dubai retail (Khaleej Times, per kilo); each holding has a form (bar,
      coin, jewellery) with a public-domain / CC0 photo (`assets/investments/`, bucket
      `investment-images`).
- [x] Shipped 21 Oct (main 2acc2f9, iOS build 37); photos uploaded; first prices fetched; the
      user's five holdings added with cost and purchase date.
- [ ] Deferred (user, 21 Oct: "not now"): backfill price history so charts reach back to each
      purchase. Source found: the currency-api archive on jsDelivr
      (`@fawazahmed0/currency-api@<date>/v1/currencies/xau.json`, also `xag`) has daily spot back
      past Dec 2024; past Dubai retail would be spot × today's retail/spot gap (24K ≈ 1.019,
      silver ≈ 1.166), stored as estimates; `holdings_value_series` caps at 400 days. Khaleej
      Times' history API returns noise outside a browser; Stooq is behind a bot check.
- [ ] Check with the user: the 1 kg bar's cost (AED 253,000 on 7 Dec 2024) is AED 253/g against
      ~311/g spot that day.

## 7. Investments: more holding types, flows, returns, links, allocation (2026-10-21)

Ask (21 Oct): valuations and flows per holding with a yearly return that separates new money
from growth; link saving transfers and card payments to holdings (RL360's USD 2,000 a month on
Tejasvie's ENBD card, today filed under "Investment", a spend category); allocation by asset
class on the net worth page.

### Decisions (user, 21 Oct)
1. A payment linked to a holding is **saving**: it leaves spend, budgets and the spend charts and
   shows in cash flow as Saving → <holding>.
2. Holding types now: metals (priced by the feed), **plans** (RL360-style), **broker accounts**
   (IBKR, Swissquote, Sarwa), **shares / funds** (units × a price you enter), **fixed deposits**
   (principal, rate, maturity; value accrues).
3. Linking: a description rule on the holding links new payments automatically; any row can be
   linked or unlinked by hand (an unlinked row is never re-linked by the rule).

### Plan
- [x] Migration: `holdings.kind` (metal | plan | broker | security | deposit), currency,
      institution, units, symbol, principal / rate / maturity, link_pattern; metal-only fields
      only for metals. `holding_valuations` (evidence: a value, or a unit price for securities,
      as of a date). `holding_flows` (contribution | withdrawal | income, dated, holding currency
      and AED, optional `txn_code`, unique per transaction; removed_at instead of delete). A
      metal's cost and purchase date become its first contribution (kept in sync by
      `save_holding`).
- [x] Valuation at any instant for every kind (metals: feed; plan/broker: latest valuation;
      security: units × latest price; deposit: principal + simple profit to maturity); AED via
      the peg / `fx_rates`.
- [x] `holding_returns(profile, period)`: per holding and total for all time / this year / last
      12 months: start value, added (contributions − withdrawals), income, growth, simple % and a
      money-weighted yearly return (XIRR, from 90 days of history), computed in SQL.
- [x] Links: rule on insert/update of transactions and when a holding's rule is saved;
      `link_transaction(profile, txn, holding | null)`; `v_spend` excludes linked payments;
      `v_cash_flow` files them as saving with the holding; `cash_flow_savings` breaks saving down
      by holding; `v_transactions` and `account_ledger` show the link.
- [x] `net_worth` returns `allocation` by class (cash, gold, silver, plans, brokers, shares/funds,
      deposits; owed as negative).
- [x] Web + iOS: holding types in the form, Update value, flows list with linked rows, link /
      unlink from the ledger and Activity, returns (period switch), allocation chart, saving by
      holding in cash flow.
- [x] Later (21 Oct): exact-match rules (`link_exact`; Wio prints RL360 as "RI"), a deposit's
      principal is its first contribution, all-time returns leave out holdings with no money in.
- [ ] Ship, then create the RL360 plans in production: Tejasvie (ENBD, rule contains "RL360") and
      Hussain (Wio Credit, rule exactly "RI"); their current values when the user has them.
