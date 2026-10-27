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
- [x] Ship, then create the RL360 plans in production: Tejasvie (ENBD, rule contains "RL360") and
      Hussain (Wio Credit, rule exactly "RI"). Their values come from the RL360 sync (§8).

## 8. RL360 sync: plan values, value history and premiums from RL360's Online Service Centre (2026-10-21)

Ask (21 Oct): get RL360 plan data into the ledger instead of typing values in. The user signed in
to the Online Service Centre in the browser pane and the pages were mapped read-only.

### What the site offers (mapped 21 Oct)
- Sign-in: `POST /scripts/customer.cgi?option=login` with `USERNAME`, `PASSWORD`, `option=login`;
  plain HTML, no JavaScript needed, no second factor seen. Session is a cookie; sign out is
  `customer.cgi?option=logout`. Pages live under `/scripts/customer.cgi/SC/`.
- Dashboard `SC/` lists the plans as links to `servicing/summary.php?PolNumber=<plan>`.
- Per plan (all GET, all take `PolNumber`):
  - `summary.php`: product, status, start date, currency, current value, premium amount and
    frequency, premiums invested, last 6 premiums.
  - `valuation.php?day=&month=&year=&continue=Continue`: the value **on any past date**
    (holdings table, `Total` row, policy-value cell `td#t2header7`; fund price date per row).
    Today's view also has premiums invested, withdrawals and the estimated surrender value.
    So the plan's value history can be backfilled monthly from its start (Jan 2022).
  - `history.php?subtab=premiums&day=&month=&year=&eday=&emonth=&eyear=`: every premium (due
    date, amount due, date received, amount received, bonus); `subtab=wdls` withdrawals; totals
    (premiums, incentives, enhanced allocation, withdrawals).
  - `transactions.php` (date range): unit-level statement (premium allocations incl. the 2%
    bonus, administration / establishment / servicing charges).
  - `PDF.php?Tab=<summary|valuation|transactions|history>&…`: printable PDFs of each tab.
- Each person signs in with their own login, so Tejasvie's plan needs her credentials.

### Decisions (user, 21 Oct)
1. **Runs in Supabase on pg_cron**, not the local scraper: an Edge Function `rl360-sync`, daily
   (`'20 2 * * *'` UTC, 06:20 Dubai, after RL360's overnight fund prices). Logins live in one
   Edge secret `RL360_LOGINS` (JSON `[{profile_code, username, password}]`) that the user
   writes into `supabase/functions/.env.production` and pushes with
   `scripts/cutover/set-edge-secrets.sh`; never in chat, git or logs (Sentry scrubs the form).
   Plain `fetch` (the site needs no browser), a polite delay between requests, sign out at the
   end. Risk: RL360 may refuse cloud IPs; the first production run tells (fallback: the same
   parser from the local scraper).
2. **Premiums reconcile with linked card payments:** each RL360 premium (date received, USD
   amount) matches a linked card payment for that holding within ±7 days; unmatched ones become
   imported contributions (USD, AED at the peg), so years before the ledger's SMS history count
   and a missed SMS leaves no gap. The 2% premium bonus is growth, not new money.

### Design
- Holding ↔ plan: a new `holdings.external_ref` (the plan number), set once on the holding; a
  plan found on RL360 with no holding is reported, not created.
- Valuations: `source = 'import'`, one per holding and date; a re-run replaces an import, never
  a manual value. First run backfills month-end values from the plan start; then today's value.
- `import_holding_data(...)` (service role) does the matching and writing in SQL; the function
  only fetches and parses. `cron_runs` records each run like the other jobs.

### Plan
- [x] Migration: `holdings.external_ref`, `holding_flows.source`/`external_ref` (unique per
      holding), `import_holding_data(...)` (service role, reconciliation), cron job, pgTAP.
- [x] Edge Function `rl360-sync` (`withSentry`, `requireCron`, `runCronJob`): login, plan list,
      valuation by date, premium history; parsers tested on saved, anonymised HTML; the login
      form scrubbed from Sentry; `config.toml` `verify_jwt = false`.
- [x] Web + iOS: "Synced" on imported values and premiums; the value list shows the latest 12
      (a value a day). The plan number is claimed by the sync, so the form needs no field.
- [ ] Production (ask each time): ship; user adds `RL360_LOGINS` and pushes the secret; set each
      plan's `external_ref`; run the job once and check the backfill.
- [x] Docs: CHANGELOG, ARCHITECTURE, PRODUCTION (function, secret, cron), README.

### Review (21 Oct)
- Built locally on `wio-accounts` (not pushed). pgTAP `68_rl360_sync` (31 checks), deno parser
  and session tests, LedgerKit and web tests; the CI mirror passes (15 checks).
- The parsers were run against the live, signed-in pages (read-only): 58 premiums totalling
  USD 116,000 (RL360's "premiums invested"), backdated values for any month-end.
- Locally: 401 without the cron secret, a clean skip without `RL360_LOGINS`; a seeded plan shows
  synced values and premiums, and +25.4% matches RL360's own figure.
- Not yet run: a real sign-in from the function (needs the owner's login in
  `supabase/functions/.env`), and from Supabase's cloud IPs (production's first run tells).


## 9. ADCB consolidated statement: bank accounts, their lines and the fixed deposit (2026-10-21)

Source: the monthly "Consolidated Statement of Accounts" from `estatement@adcb.com` (PDF, password
= customer ID, already the profile secret `ADCB_CID`). One PDF holds: savings/current accounts
(full number, IBAN, balance), each account's lines (B/F opening, date, description wrapped over
lines, ref, value date, debit, credit, **running balance**, Total), fixed deposits (number, product,
rate, maturity, amount = principal + accrued profit), credit-card summaries and TouchPoints.
Sample: Sep 2026, accounts 810001 (Active Saver) and 820001 (Current, debit card 4467), deposit
940001 (Online Century Deposit, AED 100,000 in, 109,718.87 on 30/09, 2.00%, matures 01/04/2027).
Schema + contract change: needs the user's go-ahead before code (CLAUDE.md §12.1).

### Decisions (user, 21 Oct)
- Build it all (go-ahead 21 Oct). The deposit's start date and early rate may be assumed so the
  numbers fit: 100,000 at 2% from 22 Nov 2021 reaches 109,715 on 30 Sep 2026, AED 4 short of the
  statement, so the value runs on into the first statement value.
- The deposit's statement amount includes accrued profit; the original investment was AED 100,000.
  It does not exist in the app yet: the first statement creates it (Hussain's ledger).
- TouchPoints: dropped. Card summaries: cross-check only (the card PDFs own card statements).
- No older statements: lines the parser cannot classify are kept and reported to Sentry
  (shape only), so new layouts are learnt from production.

### Design
- **Order matters**: the sender joins the ADCB email route only after this ships. Today the card
  parser would read account rows as card lines and `resolve_statement_account` would invent a
  credit-card account.
- **Parser** (`adcb.py`): detect "Consolidated Statement of Accounts" and dispatch, as SIB does;
  try `ADCB_CID` then `ADCB_PDF_PASSWORD` (today only one is tried, `dispatcher.py:26`). Per
  account: opening (B/F), lines, closing; every line's running balance must follow from the last
  (a break is a parse failure, not a warning). Kinds from description prefixes (`PUR`, `FOREIGN
  TRANSACTION FEE`, …); anything else gets a direction-only kind and a warning. Fixtures are
  synthetic text, never the real PDF.
- **Contract** (parse-v1, additive): `document_kind = "account_statement_pdf"` with `accounts[]`
  (number, IBAN, product, currency, period, opening, closing, lines), `deposits[]` (number,
  product, currency, rate, maturity, amount, as-of) and `card_summaries[]`. Doc, pydantic, SQL
  together (§2.3).
- **Unknown lines → Sentry**: the statement carries warnings; the worker sends one Sentry event
  per document (tags: `document_code`, `bank`; extra: count and each description's *shape*, digits
  → `#`, capped length). No amounts, IBANs or names (§6); a scrubber test covers it.
- **Accounts**: `private.ingest_account_statement` resolves current/savings by bank + last 6
  digits (the SMS key), never through the card resolver; creates a missing one (Saver → savings,
  Current → current); stores IBAN and full number; lines are evidence (§1.10); closing balance
  becomes `balance_checkpoints.source = 'statement'` at period end.
- **SMS overlap**: ADCB debit SMS already capture most lines. A statement line matches the SMS
  transaction (same account, amount, direction, ±3 days; running balance breaks ties), so the
  transaction is refreshed from the statement, never doubled. Transfers and card payments then
  pair through the existing `link_card_transfer` / `v_cash_flow`.
- **Deposit**: `holdings.external_ref` = deposit number (from §8, which must land first). First
  sighting creates a `deposit` holding (institution ADCB, principal 100,000, rate and maturity
  from the statement, start date from the user). Each statement adds an `'import'` valuation;
  `holding_values` for a deposit becomes *latest import + simple accrual since it, capped at
  maturity* (the formula alone stays as the fallback). A changed maturity starts a new term
  (value carries over); a deposit missing from a later statement is flagged as matured or broken,
  not silently closed.

### Plan
- [x] Parser: layout, extraction, reconciliation, passwords, kinds, warnings; pytest + golden
      parity (from the main checkout).
- [x] Contract doc + pydantic + migration: account-statement ingest, `statement` checkpoint
      source, SMS matching, deposit import and valuation rule; pgTAP; `pnpm db:types`;
      account-reader guard (`60_bank_accounts`).
- [x] Worker: route the new document kind; the Sentry event and its scrubber test.
- [x] Web + iOS: account lines and "From statement" balances; the deposit's statement values.
- [x] Verify: parse the real PDF locally (not committed), ingest into a local profile, check
      balances 0.00 / 51.46, the deposit at 109,718.87, and no doubled SMS lines; `pnpm check`.
- [x] Docs: contract, CHANGELOG, ARCHITECTURE.
- [x] Production (approved 21 Oct): shipped (main 3864127; Supabase, parser, web, TestFlight 39
      green). The ADCB route already allowed `estatement@adcb.com` but only the card e-statement's
      subject and file name, so the consolidated email had never matched: it now also takes
      subject "ADCB e-Statement" and files `ADCB(CreditCard|Stmt).*\.pdf`, and the mailbox's
      Outlook cursors were cleared so the 13:05 UTC poll rescanned 90 days.
- [x] After the first production ingest: the deposit's principal set to 100,000 and its start to
      22 Nov 2021 (worth AED 109,845.12 on 21 Oct).

### Production check (21 Oct)
- The Sep statement (the only one in 90 days) parsed as `account_statement_pdf` 2026.10.21:
  accounts …810001 (0.00) and …820001 (51.46) with statement balances, both statements `ok`, the
  fee and the purchase as new transactions (no SMS for card 4467 or …820001 had ever reached
  production), debit card 4467 registered, the deposit added and valued, card 3687's limit
  27,000. Warning: card 6617 is not in the ledger.

### Review (21 Oct)
- Built on `wio-accounts` (`20261021115816`, parser 2026.10.21). One change from the design: a
  deposit is created from its first statement with the statement's amount and date as principal
  and start (the importer can't know the original deposit); the owner corrects them once.
- The real September PDF (kept out of git) parses to both accounts (0.00 and 51.46, both
  reconciled against the running balance and Total rows), the two lines (FX fee and Google
  purchase on debit card 4467), the deposit and both card summaries. Loaded into a local ledger
  after the real debit-card SMS: the SMS waited for account …820001, became the purchase when
  the statement created the account, and the statement line matched it (sms + statement_line); the
  fee is new; both statements `ok`; the deposit was added and valued.
- Checked in the web app (Accounts "from statement", the deposit's value history "From
  statement", AED 109,845 on 21 Oct, +1.93% a year) and the iOS simulator (Wealth overview,
  Investments, the deposit screen).
- Tests (`pnpm check:all`, all 24 pass): parser 409 (golden parity included), pgTAP all (new
  `69_adcb_consolidated`), deno 179, web 623,
  LedgerKit 654, app build.
- Found on the way: bank statements would have shown as unpaid card cycles; `statement_cycles` and
  `v_statement_payments` are now card-only.

## 10. SMS clean-up: ignored notices, card BINs, the RTA Wallet pass, and the DFM iVESTOR card (2026-10-26)

From the 26 Oct review of production SMS (Hussain 9 unparsed, Tejasvie 2; every parsed message
had a card and an account).

### Decisions (user, 26 Oct)
1. Bank notices and promotions become "(ignored)" templates; the non-bank senders (e& money,
   IndusInd) and the two blank-sender tests are marked not-a-transaction (`user_not_txn`).
2. EIB's payment confirmation names the card by its first six digits ("starting with 542459"):
   cards gain `first6`; the two cards made from those digits (•2459, •7828) merge into the real
   cards (EIB Amazon •6177, EIB RTA •4557, where the reviews put them) and are deleted.
3. The Wallet pass "RTA Platinum Card" is EIB RTA •4557.
4. DFM iVESTOR card: a bank (DFM, sender `DFM`) with a current account for Hussain. Credits are
   dividends: a seeded income category "Dividends" and a rule (DFM money-in → Dividends).
   Debit-card formats are unknown until one arrives (the LLM fallback proposes them).
5. Logo: DFM's own published file (dfm.ae apple-touch-icon), unmodified; uploaded to
   `bank-logos` with `scripts/brand/upload-bank-logos.sh` (production action).

### Plan
- [x] Migration `20261026170630_sms_noise_bins_ivestor`: `cards.first6`, the `first6` template
      field and `process_sms` resolution (the cards carrying it, else the one account earlier
      messages were bound to; never registers a card). resolve_review needed no change: a message
      without last4 is already bound to the chosen account (DB-43), which is what the fallback reads.
      `private.merge_cards` (closes the emptied card, like merge_accounts).
- [x] Content: adverts by sender (`AD-…`, ignore_reason `promotion`) instead of a FAB promo
      template; "(ignored)" FAB Key Facts, FAB due reminder, EIB payment reminder; seeded "EIB credit
      card payment received" (first6) with the two LLM templates switched off; DFM bank (FX markup
      1.15%: no purchase fee, scheme only), iVESTOR credit template, Dividends category + rule.
- [x] Production data (guarded DO blocks): first6 on •6177/•4557, both payments moved, the two
      cards merged (closed); wallet_name on •4557; the four non-bank / blank-sender messages
      `user_not_txn`; Hussain's DFM iVESTOR account and its re-run SMS.
- [x] LLM fallback: `first6` field, prompt rule, expect handling (`llm_test.ts`).
- [x] Web: an unknown_card review for a BIN-only card reads "EIB card starting 542459".
- [x] pgTAP `70_sms_cleanup`; OTP fixture, logo list, FX markup and seed counts (01, 05, 14, 20,
      25, 38) updated.
- [x] assets/banks/DFM.png (DFM's own file, unmodified) + README row; uploaded by the owner.
- [x] Docs: CHANGELOG, ARCHITECTURE (SMS path), lessons.

### Production check (26–27 Oct)
- Shipped as main 4d4f670 (approved 26 Oct); Deploy Supabase green, its pgTAP included (the
  branch's second CI run never reached pgTAP: Docker image pulls were rate-limited twice).
- No unparsed SMS left in any ledger. Hussain and Tejasvie: 3 `promotion`, 3 `other` notices,
  4 `user_not_txn`.
- DFM iVESTOR (Hussain): current account with card •5246; the 16 Oct dividend AED 113.92 posted,
  filed under Dividends; balance checkpoint AED 517.78 (sms). Logo served from `bank-logos`.
- EIB (Tejasvie): AED 62.00 on Amazon •6177 (first6 542459), AED 5,133.00 on RTA •4557 (first6
  457828); the two LLM templates off, the seeded one on.
- Wallet: "RTA Platinum Card" on •4557; the 22 Oct AED 8.00 tap is a duplicate of its SMS and its
  review resolved.
- The two merged cards (•2459, •7828) had no references left and were deleted by the owner in the
  SQL editor (27 Oct; the MCP write prompt timed out three times); verified gone.

### Review (27 Oct)
- One change from the design: the cards are closed by the migration, not deleted (a destructive
  migration stops the deploy, as merge_accounts found); the two empty rows were deleted by hand.
- First CI run: pgTAP failed on intended consequences (seed counts +1 category and rule; every bank
  needs an FX markup). DFM's markup comes from DFM's own user guide (Schedule of Fees: no purchase
  fee, Emirates NBD conversion), so the scheme part only.
- Local checks (no Docker here): deno lint/fmt/check/test (181), web lint, typecheck, test (624),
  build; pgTAP and types drift ran in CI and the deploy.

## 11. Swissquote sync: the cash account, positions, note values and history (2026-10-27)

Swissquote is read nightly by an Edge Function (`swissquote-sync`) through the web platform's
own JSON APIs. Login is plain HTTPS: a form post, then the Level-3 matrix card challenge (JSON),
with no browser and no phone push. Production had no SWQ data before this, so the sync owns the account.

### Decisions (user, 27 Oct)
- Monitor through Supabase functions (Edge secret, like RL360).
- The SWQ account behaves like every other debit account: transactions (+/−), balances, list
  and account screens.
- Each investment shows its current value. A note shows what it would fetch sold today
  (Swissquote's bid) next to what it pays if called at its next autocall date.
- History: every cash movement since the account opened, the outcomes of past notes, and the
  account's value over time.

### Design
- **Evidence: `broker_transactions`.** One row per Swissquote cash or position movement
  (`rest-api/transactions`), keyed by Swissquote's transaction id. These rows are immutable.
  A cash row derives one `transactions` row (`amount_source = 'broker'`, posted, `txn_at` = the
  booking time). Kinds: deposit, buy, sell, coupon, redemption, dividend, interest, custody fee,
  and reversal (opposite sign).
  - Descriptions reuse the rules: `NOTE COUPON <ISIN>` is income; new seed rules file `DIVIDEND`
    and `DEPOSIT INTEREST` the same way.
  - Buys and sells are transfers linked to their holding (saving, not spend).
- **Balance.** A `broker` balance checkpoint is written at each sync (Swissquote's own cash
  figure), plus the opening balance once.
- **Positions.** Each ISIN is a holding (`external_ref` = ISIN).
  - Shares are `security`.
  - Anything else is a `broker` holding until its term sheet makes it a `structured_note`;
    `create_structured_note` adopts the holding.
  - Flows come from the broker rows: buy is a contribution, coupon/dividend is income, redemption
    or sell is a withdrawal.
  - `broker_positions` keeps each day's mark: quantity, price, value, cost, P&L. It writes a
    `holding_valuations` row.
- **Note value.** A note's value is its latest market value, or what was invested when there is
  no mark yet. This changes the 27 Oct decision, at the user's request for current values.
  - `note_summary` gains `market` (bid %, value, as of, profit) and `if_called_next` (the first
    autocall scenario).
- **Notes funded from a synced account post nothing of their own.** Purchase, coupons and
  redemptions link to the broker's rows; an event settles only once its broker row arrives.
  Cancelling a note never voids a broker row.
- **History.**
  - `broker_snapshots`: one row per day with cash, positions and total. Days before the first
    sync are rebuilt from Swissquote's daily performance index and the deposits, marked
    `estimated`.
  - `broker_portfolio(profile, account)` serves the account screen: totals, positions with
    sell-now / if-called values, the series against net deposits, and sync status.
- **Term sheets.** A buy whose ticket in Swissquote Messages carries a term sheet is read with
  the termsheet-extract code and becomes a structured note automatically (reviewable; cancel
  undoes it).

### Plan
- [x] Migration `swissquote_sync`: tables (`broker_connections`, `broker_transactions`,
      `broker_positions`, `broker_snapshots`), `amount_source`/checkpoint `broker`,
      refresh_transaction branch, `import_broker_data` (service), `broker_portfolio` (member),
      note adoption/settlement/cancel changes, `holding_values` market value, seed rules.
- [x] pgTAP `72_swissquote_sync` (ingest, idempotency, balances, flows, note linking, RLS);
      privileges matrix; `pnpm db:types`.
- [x] Edge `swissquote-sync`: session (login, card), fetchers, normalisers, performance
      back-fill, term-sheet import, cron; tests with a fake fetch.
- [x] Web: SWQ account page portfolio card (positions, value chart), note market vs
      if-called, `broker` balance label; tests.
- [x] iOS: same in LedgerKit + views; tolerant decoding; tests.
- [x] Run it: local sync against the live account into the local stack, then look at web and
      iOS.
- [x] Docs: CHANGELOG, ARCHITECTURE, PRODUCTION (secret, cron), README, lessons.
- [ ] Production (each needs a yes): secret `SWISSQUOTE_LOGINS`, deploy, first sync.

### Review (27 Oct)
- **Live account, run locally.** Swissquote was read into the local stack several times from a
  fresh reset (`supabase functions serve`, cron secret), with the same result each time:
  - 77 transactions and a cash balance of USD 920.53, matching Swissquote.
  - 9 open positions, valued at Swissquote's marks.
  - 6 ended notes, all called early, each with its result.
  - 11 of the 13 term sheets in Messages became notes. The two credit-linked notes are correctly
    refused as not autocallables and stay `broker` holdings.
  - The rebuilt 2025 year-end value is within 0.02% of Swissquote's own report.
- **Found while running it.**
  - A note bought after issue counted the seller's coupons (lessons).
  - Swissquote's performance index jumps on a note's trade date and falls back at settlement:
    read as flat.
  - Notes the broker redeemed before any close was stored read as live.
  - The account's creation date is only in the passive-income config.
  - Swissquote's timestamps move between requests, so the opening checkpoint was written twice.
- **Changed from the design.** Swissquote's `rest-api/transactions` is a complete, structured
  ledger with a running balance, so no PDF is parsed (the parser contract is untouched).
  Closed positions are offered for term-sheet import too, for their history.
- **Checks.** The CI mirror passed: migrations, deno lint/fmt/check/test (210), web
  lint/typecheck/test (655)/build, pgTAP (2,068, fresh reset), types drift, swift test (690),
  xcodebuild. Web looked at in the browser; iOS run in the simulator (by its agent).
- **Production** (each step needs a yes):
  - `SWISSQUOTE_LOGINS` for Hussain's ledger is written to `.env.production`; the push script's
    dry run passes. Still to do: push it.
  - Merge (deploys the migration, both functions and a TestFlight build).
  - Run the first sync with `{"sync":true,"terms":5}`; the nightly runs read one term sheet each.

