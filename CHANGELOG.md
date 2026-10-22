# Changelog

## Gmail sync and a false iOS app hang (Sentry) — 2026-10-22

### Backend (Supabase)

- **fix** Gmail sync failed from the 2026-10-21 14:09 UTC secrets push on (Sentry 7791531695, `TOKEN_REFRESH_FAILED:invalid_client`): `supabase/functions/.env.production` had `GMAIL_SENTRY_ALERTS=on` glued to the end of `GMAIL_OAUTH_CLIENT_SECRET`, so production got a 57-character secret Google rejects. The file is split again; the fix reaches production with a re-push of the secrets.
- **fix** `scripts/cutover/set-edge-secrets.sh` refuses a value that contains another `KEY=` (two lines glued by a missing newline), tested by `scripts/cutover/set-edge-secrets_test.sh` (pre-push and CI `tooling`; `shellcheck` now covers `scripts/cutover/`).
- **change** ops-monitor's `mailbox_errors` title names each mailbox's provider and code and the fix: a refused client (`invalid_client`, `unauthorized_client`) says to check the OAuth client secret, `invalid_grant` to reconnect the mailbox.

### iOS

- **fix** sentry-cocoa 9.31.0 (from 9.30.1). Sentry starts in `LedgerApp.init`, before UIApplication exists, and older SDKs took a process launched in the background by an SMS intent for an active app, so the next resume reported the suspension as a 6-hour "App Hang Fully Blocked" (2026-10-20). 9.31.0 reads the real state at launch; `Package.swift` pins it as the floor.

### Docs

- **docs** PRODUCTION §2.5 notes the glued-line check; lesson in `tasks/lessons.md`.

## ADCB consolidated statement: bank accounts, their lines, the fixed deposit — 2026-10-21

### Parser

- **feat** ADCB's monthly "Consolidated Statement of Accounts" (`estatement@adcb.com`, opened with the customer ID) is read as parse-v1 `account_statement_pdf` (parser 2026.10.21): one statement per savings/current account with its number, IBAN, opening and closing balance and lines (value date as the transaction date, wrapped descriptions joined), plus `deposits[]` and `card_summaries[]`. The table is read by column position, and every row's running balance must follow from the last or the parse fails. `PUR` lines are purchases with their debit card, fees and profit are named; any other description keeps its direction (`transfer_in` / `transfer_out`) and is listed by its masked shape in `metadata.unrecognised_lines`.
- **fix** ADCB statements try both `ADCB_PDF_PASSWORD` and `ADCB_CID` (only one was tried), and detection recognises the consolidated statement, which names ADCB only in its logo.

### Backend (Supabase)

- **feat** Bank-account statements: an `account_statement_pdf` finds its account by number or the alert suffix (creating it, with `accounts.account_number` and `iban`), re-runs the bank's alerts that waited for that account, then matches its lines to the account's SMS transactions like a card statement. The closing balance is a `balance_checkpoints` row (`source = 'statement'`) as of the period's last moment in Dubai; a bank statement reconciles opening − debits + credits = closing.
- **feat** Statement deposits become `deposit` holdings keyed by `holdings.external_ref` (or claim the ledger's one unnumbered deposit at that bank), with an imported value per statement; the newest statement sets rate and maturity, and a deposit missing from a later statement is flagged. A deposit is worth its latest imported value plus simple profit since, to maturity (the principal formula before the first import).
- **feat** Card summaries refresh a known card's credit limit; an unknown card is a warning, never a new card.
- **fix** `statement_cycles` and `v_statement_payments` are card-only: a bank statement is not a card cycle and is never "unpaid".
- **feat** The worker reports a document's unrecognised line shapes to Sentry (one warning per document; shapes only, re-checked before sending).

### Web

- **feat** Balances from a statement read "from statement"; a deposit valued by its bank's statements lists those values ("From statement") and says it accrues from the latest one.

### iOS

- **feat** The same on the phone: "from statement" balances, and a deposit's statement values in its value history (no Update value for deposits).

### Docs

- **docs** parse-v1 documents `account_statement_pdf`; ARCHITECTURE covers bank-account statements and statement-valued deposits; plan `tasks/todo.md` §9.

## RL360 sync — 2026-10-21

### Backend (Supabase)

- **feat** `rl360-sync` Edge Function, daily (pg_cron `ledger-rl360-sync`, 06:20 Dubai): signs in to RL360's Online Service Centre with each ledger's login (`RL360_LOGINS`), reads each plan's value and premium history, and backfills month-end values from the plan's start (30 a run). Requests are spaced a second apart; it signs out after each login.
- **feat** `import_holding_data` (service role): claims the profile's RL360 plan by its plan number (`holdings.external_ref`), stores values as imports (never over a manual value of the same day), and reconciles premiums with linked card payments: a premium with a linked payment within ±7 days and 5% is that payment, any other is an imported contribution (`holding_flows.source = 'import'`). Re-checked every run, so linking or unlinking a payment later moves the premium; a premium you removed stays removed.

### Web

- **feat** A holding's value history marks synced values and shows the latest 12 until you ask for all; imported premiums read "Synced from the provider".

### iOS

- **feat** The same on the holding screen: "Synced" under synced values, the latest 12 values with Show all, and "synced from the provider" on imported premiums.

## Investments: holding types, flows, returns, links, allocation — 2026-10-21

### Backend (Supabase)

- **feat** Holdings beyond metals: savings plans, broker accounts, shares and funds (units × price), fixed deposits (accrue to maturity), each in its own currency. `record_holding_value` for plans, brokers and unit prices.
- **feat** `holding_flows`: contributions, withdrawals and income per holding, optionally the ledger payment; a metal's cost and a deposit's principal are its first contribution. `add_holding_flow`, `remove_holding_flow`, `holding_detail`.
- **feat** Linking: a holding's description rule (contains, or the whole description for short names such as Wio's "RI" for RL360) links matching payments as they arrive (and existing ones when saved); `link_transaction` links or unlinks by hand. A linked payment is saving, not spend: it leaves spend and budgets and shows as saving in cash flow; `cash_flow_savings` breaks saving down by holding.
- **feat** `holding_returns` (all time, this year, last 12 months): added vs growth, simple % and a money-weighted yearly return. `net_worth` adds allocation by asset class.

### Web

- **feat** Investments covers plans, broker accounts, shares and funds, and deposits: grouped holdings, kind-specific forms with a link rule (contains, or the whole description), Update value, a holding page with returns, money in and out and value history, a returns card (all time / this year / 12 months), allocation on the Wealth overview, Link to investment from Activity and account ledgers, and saving by holding in Cash flow.

### iOS

- **feat** The same in the Investments tab: grouped holdings, kind-specific sheets with the link rule, a holding screen (returns, flows, values), the returns card, an allocation chart on the Wealth overview, Link to investment from a transaction, and saving by holding in Cash flow.

## Gold and silver in Wealth — 2026-10-21

### Backend (Supabase)

- **feat** `metal-prices` Edge Function every 6 hours (pg_cron `ledger-metal-prices`): Dubai retail gold by karat (Dubai Jewellery Group, Khaleej Times as fallback), Dubai retail silver (Khaleej Times), and spot for reference (gold-api.com, Swissquote). Stored in `metal_prices`; a price more than 50% from the last one is refused.
### Web

- **feat** Investments (`/wealth/investments`): gold and silver at Dubai retail rates with value, gain on what you paid and the 24-hour change, a per-gram price strip, a 90-day value vs paid chart (or the 24K / silver price), holdings with a photo per form, Add / Edit / Close; weights in g, kg or tola. Wealth overview's net worth shows cash + investments − owed.

### iOS

- **feat** An Investments tab in Wealth with the same: value, gain, prices, chart, holdings with photos, Add / Edit / Close; Wealth overview's split and Investments card.

### Backend (Supabase), continued

- **feat** `holdings` (gold by karat, 24K bars by fineness 999.9/999.5/999/995; silver by purity; a form — bar, coin or jewellery — with a photo from the public `investment-images` bucket; cost optional) with `save_holding` / `close_holding`, `holdings_valuation` (value, gain vs cost, 24-hour change), `holdings_value_series`, `metal_price_series`. Net worth now counts the metals.

## Wio Credit statement and autopay leg — 2026-10-20

### Backend (Supabase)

- **feat** Wio's "credit payment is due today. Statement amount: …" SMS makes Wio Credit's month-end statement (due the day it arrives: templates gain `due_on_receipt`), so what Wio Credit owes is anchored and net worth is complete. Wio credit accounts close at month end; due-today notices already stored are read again on deploy.
- **feat** The Wio Credit autopay is also money out of the Wio debit account: a `transfer_out` leg there (`transactions.leg_of_txn_code`, templates gain `pays_from_current_account`), paired with the payment so cash flow shows one card repayment and the account's running balance no longer drifts each month. Existing autopays get their leg on deploy.

## Wealth mode — 2026-10-20

### Backend (Supabase)

- **feat** Spending and Wealth: `v_transactions` carries `account_kind` and `in_spending`; Activity's summary and filters take `scope = spending` (card rows, plus purchases, refunds, fees, interest and cash advances on any account). Salary, transfers and autopay move to the account's ledger.
- **feat** `account_ledger()`: a bank account's rows like a statement, with flow and running balance (anchored on the bank's balances), opening and closing balance, money in and out. `bank_balance_series()`: end-of-day balances.
- **feat** `net_worth()` (bank cash − what the cards owe) and `net_worth_series()`, from a nightly `net_worth_snapshots` row per ledger.
- **feat** `cash_flow()` takes an account and marks partial months (before any bank evidence).
- **feat** Insights: a stale or missing bank balance, a balance that disagrees with the alerts (a missed SMS), salary not in by its usual day, and a card's annual fee above the cashback it earned.

### Web

- **feat** A Spending / Wealth switcher at the top of the sidebar (and the phone header). Spending is Overview, Activity, Insights, Budgets and Cards; Wealth is Overview, Accounts and Cash flow; Review, Rules and Settings are in both.
- **feat** Wealth overview: net worth (bank cash − what the cards owe) with what it's missing, net worth over time, bank accounts, owed on cards, this month's cash flow and the wealth insights.
- **feat** Account page (`/wealth/accounts/:code`): balance and Update balance, a 90-day balance chart, the month's opening, money in and out and closing, and a statement-style ledger with flow, category (editable), amount and balance after.
- **change** Cash flow moves to `/wealth/cash-flow` (the old path redirects), with an account filter and partial months marked. Activity shows spending only (debit-card purchases tagged Debit; salary and transfers live in the account ledger). Overview's Cash tile is gone.

### iOS

- **feat** A Spending ⌄ / Wealth ⌄ menu at the top of each root screen swaps the tab bar (remembered on the device): Spending is Overview, Activity, Insights, Budgets, Settings; Wealth is Overview, Accounts, Cash flow, Settings.
- **feat** Wealth overview (net worth and what it's missing, net worth over time, bank accounts, owed on cards, this month's cash flow, wealth insights); Accounts; an account ledger with a 90-day balance chart, the month's opening, in, out and closing, and each row's flow and balance after (tap to file a transfer).
- **change** Activity shows spending only, with debit-card purchases tagged Debit; Cash flow is its own Wealth tab with partial months marked; the Cash tile and Cash & accounts screen are gone.

## Wio debit and Wio Credit — 2026-10-20

### Backend (Supabase)

- **feat** Wio alerts: local transfers from the debit account or Wio Credit (the recipient becomes the description), international transfers (the AED debited), the Wio Credit autopay (a payment on Wio Credit), cashback, and card purchases that print their AED amount. Due, estimate and new-beneficiary notices are ignored.
- **feat** An alert's account digits can name a credit line (Wio Credit …5059), so its transfers to pay other cards pair with those cards' payments and count once. A transfer is final from its SMS on any account.

## FAB salary and moves between your own accounts — 2026-10-20

### Backend (Supabase)

- **feat** FAB's "Salary Credit" alert is captured (with its balance) and a seed rule files it under Salary.
- **feat** FAB's funds-transfer confirmation becomes a `transfer_notice`: it names where the money went (`counterparty_ref`) and never becomes a transaction. A transfer to one of the ledger's own bank accounts (named by the notice, or matched by the other account's same-amount transfer within 3 days) shows in cash flow as a move, not as money out or new money in.
- **fix** A bank alert waiting for its account is reported as such, not as "not a card purchase". Rules can test the transfer kinds.

## Cash flow and bank account screens (Phase 2d) — 2026-10-20

### Backend (Supabase)

- **feat** `cash_position()`: each bank account's balance, as-of and staleness, and the AED total. `filter_meta` lists bank accounts again, with their kind and digits.

### Web

- **feat** Cash flow page (`/cash-flow`): bank accounts with balances, Update balance and Add bank account; the month's money in, committed, spent, unfiled out and moves, the net, and six months of net. Overview gets a Cash tile when the ledger has a bank account. Activity's account filter names bank accounts ("ADCB · Current ··· 810001").

### iOS

- **feat** Cash & accounts screen from a new Overview Cash tile: balances, Update balance, Add bank account, the month's cash flow and six months of net. The spend filter sheet gains All cards / Credit / Debit.

## Cash flow, saving and support, card type filter (Phase 2c) — 2026-10-20

### Backend (Supabase)

- **feat** Category kinds `saving` and `support`: money to family and to savings or investments is its own flow, never spend. Every ledger gets Salary, Transfers, Family support and Savings & investing (added only where a category of that name is missing).
- **feat** `v_spend` carries `instrument` (credit or debit card); `spend_series` and `spend_breakdown` take `p_instruments`.
- **feat** Paying a card from a bank account counts once: a bank transfer out pairs with the card payment of the same amount within 3 days (`card_transfers`).
- **feat** `v_cash_flow` and `cash_flow()`: each month's money in and out by flow (income, spend, support, saving, card repayments, internal moves, unfiled money in and out) and the net. Payees are category rules on kind, amount and bank.

### Web

- **feat** Insights → Trends: an All cards / Credit / Debit switch (`?inst=`). Category editor offers Family support and Saving & investing.
- **fix** Insights no longer crashes on an invalid `?range=` (or any dropped search key): the route returns dropped keys as undefined.

### iOS

- **fix** Spend filters leave support and saving categories out, as they do transfers.

## Debit-card and bank-account SMS (Phase 2b) — 2026-10-20

### Backend (Supabase)

- **feat** Debit-card purchases and bank-account alerts become transactions on the ledger's bank accounts. New SMS kinds `debit_purchase`, `account_credit` and `account_debit` map to `purchase`, `transfer_in` and `transfer_out`, posted straight away. New templates: ADCB account credit and debit, ADCB and FAB debit-card purchases, FAB outward and inward remittances. They read the account digits (`account_ref`) and the printed balance, which becomes a balance checkpoint. The seeded "(ignored)" versions are switched off while they still hold their seeded pattern.
- **feat** An alert resolves to the debit card's account, else the account it names, else the bank's only bank account. A new debit card is registered on its account. An alert for an account the ledger doesn't have waits (`no_bank_account`) and is re-run when the account is added.
- **feat** A debit-card purchase counts as spend; transfers in and out don't. The same alert sent twice (two automations) is dropped as a repeat.
- **feat** The LLM format proposer knows the new kinds and the `account_ref` field.

### Web

- **feat** SMS guide: an optional second automation on "Account" for bank-account alerts. Rules can test the transfer kinds.

### iOS

- **feat** SMS guide step 7: an optional second automation on "Account" for bank-account alerts.

## Bank accounts and balances (Phase 2a) — 2026-10-20

### Backend (Supabase)

- **feat** A ledger can hold current and savings accounts beside its cards (`accounts.kind`, `account_ref`), added with the owner-only `create_bank_account`. `record_balance` records a balance (a decimal string, now or dated earlier) as a `balance_checkpoints` row, and `v_bank_balances` gives each bank account's balance: the latest checkpoint plus its transactions after it, marked stale after 7 days. No screens yet (Phase 2d) and no SMS capture yet (2b).
- **fix** Every reader that assumes an account is a card now says so: card outstanding, Overview's card list, the filter options, review resolution and the "bank has one account" fallbacks in SMS and statement matching skip bank accounts, and `merge_accounts` refuses to merge a bank account with a card. `60_bank_accounts.test.sql` lists every function that reads `accounts`, so a new one fails the build until it is classified.

### Web

- **fix** Card screens (card names, budgets, account comparison, review) list card accounts only.

### iOS

- **fix** Budgets, account comparison and the review picker list card accounts only.

### Docs

- **docs** ARCHITECTURE.md: bank accounts and `v_bank_balances`; `tasks/todo.md` §3: the Phase 2 plan.
## Financial audit data-quality fixes — 2026-10-20

### Parser

- **fix** Parser 2026.10.20: a credit-card cash withdrawal is kind `cash_advance`, not `purchase`. An ATM abroad is printed as its bank's name (FAB "DTBKEN NAIROBI KEN", KES 5,000), so the purchase line that a CASH ADVANCE FEE follows (same card, same date, only fee/VAT lines between) is marked `cash_advance` (`ccs_parser.kinds.pair_cash_advances`), and descriptors with `ATM`, `CASH WITHDRAWAL` or `CASH WDL` are cash advances on their own.

### Backend (Supabase)

- **fix** SIB's WAKALA PROFIT and BONUS credits are Bank Fees & Interest credits, not Cashback, so they net off the same-day MURABAHA PROFIT charge in `v_spend` (May 2026: 348.90 − 341.57 − 7.33 = 0). As Cashback (`kind = 'income'`) they were left out of spend while the charge counted in full: AED 1,669.03 of overstated fees on one profile for Apr–Jul 2026. The WAKALA seed rule moves category (credits only); BONUS gets an SIB-only credit rule at priority 90 (`private.seed_rules.priority` is new), so other banks' BONUS credits stay Cashback. Guarded content migration; existing profiles recategorise through the rule triggers.
- **fix** Cash withdrawals already ingested as purchases are corrected once, with the parser's pairing rule (`private.mark_paired_cash_advances`, run by the migration): in production the FAB Nairobi (2026-09-24), ADCB Phuket (2025-08-29) and ENBD Meydan (2025-01-05) withdrawals. A re-parse can't do it: a revived line keeps its stored kind.
- **fix** Recurring detection (`private.detect_recurring`) finds monthly bills whose amount varies. Charges to one merchant on one day are one billing event (Etisalat's two bills on the 1st no longer break the cadence), and a monthly series with steady gaps (4+ events, 75% of gaps 26–35 days) is recurring at any `amount_cv` (DEWA, AED 286–417); everything else still needs cv < 0.10. Frequent variable purchases (Apple in-app, Tesla Supercharger) have no monthly gap and stay out. In production this adds DEWA, Etisalat and SIB's Murabaha profit charge on the next nightly run.
- **feat** A `cash_advance` insight (new `insights.kind`): every cash advance of the last 30 days gets a heads-up with the amount, the original currency and the bank's same-day CASH ADVANCE FEE plus its VAT, linking to the transaction; it expires 30 days after the withdrawal. `private.generate_insights` is otherwise unchanged.

### Web

- **feat** The Insights feed files `cash_advance` under Spending and links it to the transaction, like `large_transaction`.

### iOS

- **feat** "Worth a look" files `cash_advance` under Spending and opens the transaction, like `large_transaction`.

## Capture intents are actions, not App Shortcuts — 2026-10-18

### iOS

- **fix** "Log Bank SMS" and "Log Card Payment" are no longer App Shortcuts, only Shortcuts actions. On iOS 26 a Transaction automation's "Do" picker offered the "Log Card Payment" App Shortcut tile, which runs with no fields to bind to Shortcut Input, so every tap arrived without merchant or card and was refused. The actions stay discoverable (`isDiscoverable`), and the in-app guides (Set up SMS capture, Set up card payments) now say to add the action that reads "Log Amount at Merchant on Card" / "Log Message from Sender". The Siri phrases "Log card payment in Bank Ledger" and "Log bank SMS in Bank Ledger" are gone: they ran with empty fields and could never log anything. An automation already built from the action is unaffected; one built from the tile must be rebuilt with the action. Guarded by LedgerKit `BackgroundIntentParameterGuardTests`.

## TestFlight release retries App Store Connect — 2026-10-16

### iOS

- **fix** `testflight-distribute.mjs`: every App Store Connect request has a 60 s timeout, and a GET is retried (5 s, 15 s, 45 s) on a network error, a timeout, 429 or 5xx. Build 33's release step failed with a bare `fetch failed` after Apple's API didn't answer its first call for 5 minutes, although the upload had worked; a re-run released it. POSTs are still sent once. Tested by `asc-retry.test.mjs`, run from `release_checks_test.sh`.

## Capture intents never ask for a value — 2026-10-16

### iOS

- **fix** "Log Bank SMS" (Message) and "Log Card Payment" (Merchant, Card) take optional parameters. A required one that arrived empty in a personal automation made iOS ask for a value instead of running the intent, and build 32 hung on launch with that request in flight (Sentry 7796165023). Empty input now reaches LedgerKit, which drops an empty SMS and refuses a payment with no merchant or card, with its reason. Guarded by LedgerKit `BackgroundIntentParameterGuardTests`.

## SIB history exports close on the 14th — 2026-10-15

### Parser

- **fix** Parser 2026.10.15.1: SIB history exports are bucketed into cycles closing on the 14th (15th to 14th), not the 12th, so rows dated the 13th and 14th land in the cycle the bank bills them in and the export pairs with the cycle's SMS statement on the same date.

### Backend (Supabase)

- **fix** `private.rebucket_history_lines` (called by `ingest_one_statement`): a history row that arrives on a history statement with another date while it is still current on an older one moves to the new statement with its transaction, evidence and documents, instead of creating a duplicate transaction; an old history statement left with no current row is superseded by the new one. The existing 12th-dated SIB exports turn into 14th-dated ones the next time an export is uploaded or re-parsed, with every transaction code and user field kept.
- **feat** An export whose cycles close on another day than the account's `cycle_close_day` adds an ingest warning.
- **fix** A line's identity (`line_key`, `private.statement_line_key`, now the only definition ingest uses) ignores letter case: SIB's card-summary and billed "Statement details" exports print one row as `…SERVICEDubai` and `…SERVICEDUBAI`, which made two lines and a duplicate transaction. The migration re-keys existing lines (`private.rekey_statement_lines`): case variants of one row in a statement merge into the older line, and the duplicate transaction hands over its SMS/statement evidence, notes and manual category and is voided (`duplicate_line`).

## SIB statements from the statement-summary SMS — 2026-10-15

### Backend (Supabase)

- **feat** SIB's monthly "payment is due … outstanding amount … minimum payment due" SMS now makes a statement (`msg_kind = 'statement_summary'`, new SIB template) for the cycle that closed before it arrived, with the closing balance, minimum due and due date. SIB gets a payment status, the due-date reminder, a statement anchor for its outstanding balance and a "latest statement" on Overview. The SIB •5052 account's close day is set to the 14th (confirmed by the owner), so the existing 2026-10-14 SMS is reprocessed on deploy into the 2026-10-14 statement.
- **feat** `public.v_sms_statements`: an SMS statement takes its lines from the cycle's history export and is checked live against the ledger (previous closing + the cycle's pending and posted transactions); the gap shows missing spends or a history export not uploaded yet. A charge still pending on the close day counts in the next cycle, since the bank closes with what has posted. `statement_cycles` lists the pair as one row (new `from_sms` column) and `statement_detail` carries `from_sms` and `history_stmt_code`.
- **fix** `v_account_balances`: activity on top of an SMS statement is counted by date after the close, plus close-day charges still pending, so pending SMS spends inside the closed cycle aren't counted twice. For SIB this gives AED 4,497.21, the bank's own figure.

### Web

- **feat** Statements: an SMS statement is labelled "from SMS", has no Open PDF, and its check reads "The ledger adds up to the closing balance in the bank's SMS" with the ledger total and the gap; a missing history export is called out.

### iOS

- **feat** Statements: "SMS statement" rows and detail, a "No history export" chip, the ledger-vs-SMS check as a sentence, and no PDF button for an SMS statement.

### Docs

- **docs** ARCHITECTURE.md: SMS statements and their balance anchor rule.

## SIB billed "Statement details" detected — 2026-10-15

### Parser

- **fix** Parser 2026.10.15: the SIB app's "Statement details" export in its billed-statement view (Statement date, Opening balance, Payment due date) is detected as SIB. Its only bank name is the header logo image and, unlike the card-summary view, it has no "Card issuer SIB" line, so an upload without a bank hint failed permanently with `BANK_UNDETECTED` (Sentry 7783440279). Detection now reads the template: the title, the bare masked "Card 5290 xxxx xxxx 4821" line and the "Date Details Amount" header. It parses as a history extract, like the card-summary view.

## Outlook token refresh diagnostics — 2026-10-14

### Backend (Supabase)

- **fix** A failed Microsoft token refresh names the AADSTS code, e.g. `outlook token refresh failed: HTTP 401 invalid_client AADSTS7000222` (expired client secret), instead of only `invalid_client`, which also covers a wrong secret or a deleted app. Codes only: `error_description` is never copied. `last_error` stays `TOKEN_REFRESH_FAILED:invalid_client`.

### Docs

- **docs** PRODUCTION.md §6.5: rotating the Azure client secret (`MS_OAUTH_CLIENT_SECRET`) and where to record its expiry; a lesson on `invalid_client` vs `invalid_grant`.

## Backlog batch 8: iOS parity, no "pending" — 2026-10-14

### Web

- **change** SMS and payment-shortcut charges look like any other transaction: no Pending badge, no "Pending from SMS" strip, no Pending or Posted status filter. Overview keeps a quiet "Last card alert …" line.
- **fix** An old `?status=pending` link no longer filters Activity: the router laid the validated search over the raw URL, so a key the codec dropped survived.

### iOS

- **add** Insights "Worth a look" feed with every open insight, linked where the web links, dismissable by owners; Unusual spending with "This is fine" (PAR-9).
- **add** Insights → Trends: range presets and custom dates, day/week/month buckets, grouping by category, bank, merchant, account or card, filter, stacked chart; rows and bars open Activity (PAR-10).
- **add** Activity bulk select for owners: tick rows or select every match, then Categorise or Exclude / Include (PAR-11).
- **add** More analysis: daily spending calendar, weekday × hour, year over year, foreign currency, and every subscription (PAR-12).
- **add** Statements compares accounts with balance, utilisation and spending sparklines; a statement opens its PDF (signed URL, held in memory only) (PAR-13).
- **add** Review accepts or rejects an AI-proposed SMS format; every SMS review can show its message on request (PAR-14).
- **change** No "pending" anywhere: no Pending badge, strip, hero "+ AED X pending" line or Pending/Posted filter; the hero reads "October 2026 · so far" (it always included SMS charges); widgets read "October so far".
- **fix** Statement cycles open again from Settings → Statements. Since build 29 the Settings stack's typed path had no destination for a cycle, so the row did nothing; a test now fails on any other value pushed there.

### Docs

- **change** BACKLOG: iOS parity PAR-9…14 done; the parity section is closed.

## Backlog batch 7: iOS parity with the web — 2026-10-14

### iOS

- **add** Activity filters match the web: This month, Last month, Last 3 months, This year or a custom range; card; Void status; SMS / statement / both source (PAR-1).
- **add** A transaction sheet everyone can open: viewers read-only, owners with the details in the edit sheet. Status, kind and source badges, Awaiting FX rate / AED estimated, time and posted date, card, merchant context, FX rate, the reversal pair, and the evidence timeline with the SMS text shown on request and never kept (PAR-2).
- **add** Activity date headers show each day's net over every matching transaction (`activity_day_totals`) (PAR-3).
- **add** Other screens open Activity filtered: Overview's uncategorised count, pending strip and recent rows, Insights' top merchants, and a category's "See transactions" (PAR-4).
- **add** Category drill-down from Insights and the Overview ring (slices are tappable): monthly trend, top merchants, change vs the previous period (PAR-5).
- **add** Overview's current month shows a pace rule (last month and the 3-month average by today) and the projected month end (PAR-6).
- **add** Budget meters show an expected-by-today tick and "AED X over/under pace" (PAR-7).
- **add** Insights categories show the change vs the previous period and list every category; merchants show the top 20 (PAR-8).

### Docs

- **change** BACKLOG: iOS parity PAR-1…8 done; PAR-9…14 remain.

## Backlog batch 6: payment status, analytics, widgets, Shortcuts, notifications, Wallet currency — 2026-10-13

### Backend (Supabase)

- **add** `20261013180516_statement_payment_status`: `v_statement_payments` gives each statement `payment_status` (`paid` / `part_paid` / `unpaid` / `overdue`) and `amount_paid`, carried by `overview` (latest statement), `statement_cycles` and `statement_detail`. Overdue: due date passed and payments so far under the minimum; a minimum paid late is part paid (UX-1r, WEB-36).
- **add** `activity_day_totals` (per-day net for the Activity headers, the same filter reader as the bulk RPCs) and `merchant_context` (visits, average, 6-month total, first seen, from `v_spend`) (MA-3, MA-4).
- **fix** `20261013183327_statement_due_skips_paid`: the nightly `statement_due` insight skips statements already paid.

### Web

- **add** Dues read "Due today" / "Due tomorrow" / "Due in N days" and Paid / Part paid / Overdue from the server, on Overview, Statements and the statement page (WEB-36).
- **add** Activity date headers show each day's net; the drawer shows the merchant line (MA-3, MA-4).
- **add** Category drill-down at `/insights/category/<code>` (trend, top merchants, change vs previous period); Cards compares accounts with balance, utilisation and spending sparklines; Insights "Worth a look" tab lists every open insight by the screen that answers it (MA-1, MA-2, MA-5).

### iOS

- **add** Overview hero shows "+ AED X pending"; dues say Paid, Part paid or Overdue from the server (UX-1r).
- **add** Local notifications: unknown card, captures not sent after an hour, captures waiting while signed out, and statement due reminders 3 days before and on the due date at 09:00 Dubai (withdrawn when paid). One switch per kind in Settings → Notifications; permission is asked from the SMS guide (N-1).
- **add** Widgets (new `LedgerWidgets` extension): Month spend and pace, Next due (paid statements dropped), Utilisation, on the Home and Lock Screen, from an App Group snapshot with no network; no amounts on the Lock Screen with Require Face ID (N-2).
- **add** App Intents and Shortcuts phrases: Month Spend, What's Due, Categorise Last Transaction (N-3). Controls: Open Uncategorised and Add Statement, with `ledger://uncategorised` and `ledger://add-statement` (N-4).
- **change** Log Card Payment takes Amount, Merchant and Card from the Wallet transaction automation; the currency comes with the amount (including Arabic-locale symbols); "Currency if missing" applies only to an amount with no currency; an unrecognised or ambiguous symbol (for example `$` on an en_GB phone) is refused, never guessed.
- **add** The SMS guide shows step 5 in three Shortcuts-editor screenshots (IOS-06g). A test fails the build on Apple product names in intent, widget and Control text.

### Docs

- **change** BACKLOG: batch 6 done (12 items); N-5 closed by decision; iOS parity rows PAR-1…14 added.

## iOS app hangs from build 26 — 2026-10-13

### iOS

- **change** Sentry reports only app hangs that fully block the screen (2 s); non-fully-blocking hangs, whose stacks don't show the blocking call (build 26: system text selection on an iOS beta), are no longer sent. The App Intent and share extension still track no hangs.
- **fix** The Face ID lock reads which method the device has off the main thread, when the app becomes active, at unlock and when the setting is turned on, instead of a synchronous `LAContext` call on every redraw.
- **fix** Statements reads the share-sheet queue and picked PDFs off the main thread; the App Group folder and settings are resolved once at launch.

## Backlog batch 5: release-config hardening, polish, accessibility, lighter Overview — 2026-10-13

### Backend (Supabase)

- **change** `20261013111525_uk_uncategorised`: `category_breakdown`, `spend_series` and `spend_breakdown` label no category "Uncategorised"; pgTAP 46 keeps the US spelling out of function bodies (WEB-31).
- **add** `20261013112601_budget_status_pace`: `budget_status` adds `expected_share`, `expected_aed` and `over_pace_aed` for the current month (null otherwise) (WEB-38).

### Web

- **change** One decimals rule (`formatTotal`, `<Money total>`): transactions two decimals; limits, averages and totals whole units; the outstanding balance and statement totals stay exact (WEB-34). "Uncategorised" everywhere, with a source guard (WEB-31).
- **change** Overview: the pending strip is one line from the server's count and sum, linking to pending Activity; pending rows appear once, in Recent activity, and nothing claims "No SMS" before the overview loads (WEB-35).
- **add** Budget meters show an "expected by today" tick and "AED X over/under pace" from the server (WEB-38).
- **fix** Notes no longer stay dirty after saving padded text; the rule preview shows exact counts (WEB-49).
- **fix** Accessibility: valid `dt`/`dd` groups, named meters (`Meter.label` required), the 404 inside the shell when signed in, a "Skip to content" link (WEB-52).
- **perf** Overview's category ring is SVG and the monthly bars load Recharts lazily, so Overview renders without the 107 kB (gz) chart chunk; the bundle budget enforces it (WEB-53). A `usePager` reset test (WEB-55).

### iOS

- **change** Release builds read only `Config/Secrets.Release.xcconfig`; a missing or local value fails the "Check release config" phase; `testflight.sh` and `publish-build.sh` check the archived app, the share extension and the staged IPA with `plutil` (shape only). Sentry releases (`ledger-ios@<version>+<build>`: dSYMs, new, set-commits, finalize) never block a release; `SENTRY_AUTH_TOKEN` comes from the shell or the keychain item `ledger-sentry-auth-token`, never an xcconfig. Every build script phase hides the build environment (IOS-21r, X-28).
- **fix** Sentry never receives a URL's query string or fragment (failed requests, breadcrumbs, spans); `NSAllowsLocalNetworking` ships only in Debug (IOS-30).
- **add** `ledger://review` deep link (waits for a ledger, dropped on sign-out); Shortcut results for an unknown-card or held SMS, or a held card payment, say "Needs a look in Review" and never open the app (IOS-07r).
- **perf** Activity rebuilds its day sections only when rows change or the day rolls over; shared, locked ISO formatters (IOS-26). No Swift 6 warnings (IOS-25r). "Uncategorised" spelling (WEB-31).

### Scraper

- **fix** `ccs-scraper upload` records the requests that succeeded on a partial failure, lists failed files with a retry line, and exits 1 without a traceback; uploads are tracked by path, so same-named PDFs in different folders aren't swapped (SRV-16r).

### Docs

- **change** BACKLOG: batch 5 done (14 items, 29 open); 03/04/05/06 Fix status; README, ci-cd, PRODUCTION and apps/ios docs for the release config and keychain token.

## Backlog batch 4: Activity bulk actions and export, iOS transaction sheet, Dubai dates — 2026-10-13

### Backend (Supabase)

- **add** `20261013042808_activity_bulk_actions`: `activity_selection_summary` (count, net AED, excluded count), `bulk_update_transactions` (owner; `exclude_from_spend` and/or `manual_category_code` only) and `activity_export` take either ticked transaction codes or the Activity filter (read exactly as `activity_summary`), never neither or both; money is returned as decimal strings (WEB-24).
- **change** `20261013042809_large_transaction_merchant_title`: the nightly `large_transaction` insight is titled with the merchant name, falling back to the cleaned description (WEB-16r).

### Web

- **add** The Activity bulk bar shows the selection's count and net AED from the server, "Select all N" (the whole filter), Exclude/Include from spend and Export CSV (formula-safe cells, including behind leading spaces, decimal-string money, UTF-8 BOM). Viewers can select and export; Categorise and Exclude stay owner-only (WEB-24).
- **fix** The rule editor leaves regex syntax to the server preview, so Postgres-only syntax such as `(?b)…` can be saved (WEB-13r).
- **fix** A `txn=` link to another ledger's transaction says so and offers to switch, instead of loading it under the wrong ledger (WEB-46).
- **fix** Dates taken from timestamps (members, passkeys, tokens, secrets, relative time) show the Dubai day (WEB-47).
- **fix** New service-token plaintext, PDF passwords and mailbox refresh tokens leave the request cache as soon as the form closes (WEB-50).

### iOS

- **add** The transaction sheet opens full height with category search; "None" clears a manual category; "Apply to every … transaction" starts on unless the category is that transaction's own choice; "Exclude from spend" and notes (owners). Activity rows swipe for Categorise and Exclude/Include; excluded rows say "Excluded" (IOS-18).
- **fix** The overview model decodes by the server's snake_case keys instead of Foundation's `spendAvg3M` mapping, and carries `spend_avg_3m_to_date` and `projected_month_end` (X-33r).

### Docs

- **change** BACKLOG: batch 4 done (8 items); IOS-21r built on a branch and held back until the Sentry token is in the keychain. Lesson: build `supabase.rpc` arguments as a typed variable.

## Backlog batch 3: plain anomalies, one-call review context, first-run checklist, deep links, scraper state files — 2026-10-13

### Backend (Supabase)

- **change** `20261012234036_anomalies_plain_and_dismissals`: `anomalies` returns `merchant_name`, `category_name`, `baseline_scope` and `times_usual`; a first purchase is flagged only at a known merchant, from AED 500 and at least 2× the category's usual; the baseline comes from the scope that flagged the charge. It is now SECURITY DEFINER with a member check (a non-member gets 42501) (WEB-16).
- **add** `dismiss_anomaly` (owners) and `anomaly_dismissals`: "This is fine" is durable, dismisses the matching insight, and the nightly feed skips the charge (WEB-16).
- **add** `20261013001856_review_context`: `review_context(profile, review_codes[])` returns a page of reviews' context in one call, without SMS bodies (WEB-10r).

### Web

- **fix** Anomalies show merchant names and one plain sentence ("About 5× what you usually spend here"), with a "This is fine" action for owners (WEB-16).
- **perf** The Review page loads every card's context in one request per page; transaction events refetch only the open-review list (WEB-10r).
- **add** An empty ledger's Overview shows a "Get your ledger going" checklist (statement, mailbox, statement passwords, SMS capture, member) instead of AED 0.00; each step is ticked only by server data, unknown when it can't be read, and a pending invite reads "Invite sent" (WEB-27).
- **add** Sign-in keeps the deep link: `/signin?redirect=<path>`, same-origin relative paths only (WEB-39).

### Scraper

- **fix** `uploaded.json` and `bank_map.json` are written atomically; a corrupt file is kept as `<name>.<timestamp>.corrupt` with a warning instead of silently resetting; uploads are matched by the server's cleaned-up filename, so long or padded names are recorded (SRV-16).

### Docs

- **change** `scraper/README.md` and `scraper/.env.example` document `CCS_SCRAPER_UPLOAD_MAX_FILES` / `_MAX_MB` and the batch-and-retry upload; setup uses uv (NEW-3). BACKLOG: batch 3 done (8 items incl. IOS-11), new rows WEB-16r and SRV-16r.

### Tooling

- **fix** `pnpm db:types` / `db:types:check` stable-sort each `Relationships` array (`packages/db-types/scripts/gen-types.mjs`), so the generated types no longer flip between resets; a failed generation no longer wipes `database.ts`; `pnpm db:types:test` (X-34).

## Backlog batch 2: pace projection, 16-hue palette, lighter first load, iOS outbox, privacy lock, set-up checklist — 2026-10-13

### Backend (Supabase)

- **add** `20261012215047_overview_pace`: `overview` returns `spend_avg_3m_to_date` (the previous 3 months to the same day of the month, Asia/Dubai) and `projected_month_end` (spend so far plus the usual rest of the month, averaged over the months that have spend; the run rate for a new ledger), from the new `spend_pace` and `month_to_date_end` (WEB-26).
- **change** `20261012220834_category_palette_16`: ten seeded categories move to cat-5/8/11/13–16, only while they still hold their seeded colour (WEB-17r).

### Web

- **fix** The Overview pace rule compares month-to-date spend with the 3-month average by today, shows "Projected AED X by 31 Oct", and keeps the pin labels apart on phones (WEB-26).
- **change** The category palette has 16 colours (cat-13 to cat-16 new), at least 15 ΔE apart in both themes; bank and merchant series and the colour picker use all 16 (WEB-17r).
- **perf** First load 377 → 177 kB gzipped: Sentry loads after first paint and only in deployed builds (Replay after it, early errors queued), the app shell is lazy, and `/signin` and `/privacy` load no Radix or charts. A bundle budget runs in every build (200 kB gz first load; no Radix, charts or Sentry on the first load, `/signin` or `/privacy`) (WEB-11).

### iOS

- **fix** An SMS or card payment captured with no "SMS go to" ledger is saved and sent once a ledger is set, instead of being discarded. Each item is stamped with the last signed-in account and is only filed for that account; another account's items wait in Not sent with Delete. "SMS go to" is cleared on every sign-out path (IOS-12r).
- **add** Sign-out asks first, naming how many SMS, card payments and PDFs are waiting, signs out, then deletes exactly those (a failed delete is reported); a Settings badge and an Overview strip show items that haven't reached Bank Ledger for over an hour (IOS-12r).
- **add** The app is covered in the app switcher by an opaque cover in its own window, above any open sheet; optional Settings → Privacy → Require Face ID, switched off automatically when the device no longer has Face ID or a passcode (IOS-22).
- **add** An empty ledger shows a set-up checklist (SMS capture, a statement, a member) instead of "AED 0" (IOS-23).
- **fix** Budgets use `budget_status`'s `is_effective` (`p_include_inactive`) instead of working out on the phone which budget applies (WEB-28i).
- **change** `ChartPalette.categoryTokens` is generated from the tokens; bank and merchant colours cycle through 16 (WEB-17r).

### Docs

- **change** BACKLOG: batch 2 done (7 items), new row X-34 (types ordering); 04/05 Fix status; README Overview and Settings screens, overview RPC fields.

## Card payments logged from the phone's wallet — 2026-10-13

### Backend (Supabase)

- **add** `20261012214923_wallet_transactions`: `ingest_wallet_transactions(p_profile_code, p_items)` (owner only, ≤ 200 items of `{client_msg_id, occurred_at, amount, currency, merchant, pass_name}`, amount as a decimal string) stores each payment as an `sms_messages` row with the new `source = 'wallet'` and `wallet_pass_name` (sender `Wallet`, body `<CUR> <amount> at <merchant> (<pass name>)`) and returns the `ingest_sms` result shape and statuses. `process_sms` resolves a Wallet row's card by the new owner-editable `cards.wallet_name` (unique per profile, case-insensitive; column grant to `authenticated`). An unknown name opens an `unknown_card` review (candidates `[{wallet_name}]`) that resolves itself when the name is set on a card; `resolve_review`'s register-card action refuses Wallet rows (22023). A bank SMS and a Wallet event for the same purchase (same account, amount and currency, within 30 minutes, either order) become one transaction with two evidence rows; SMS-only profiles are unaffected. Two Wallet events are never duplicates of each other (`match_sms`'s duplicate-alert step skips Wallet↔Wallet pairs; redelivery is deduped by `client_msg_id`), so identical taps minutes apart are separate transactions; SMS↔SMS duplicate detection is unchanged. pgTAP `39_wallet_transactions`.

### Web

- **add** Cards → edit a card account: a **Wallet name** field per card (the card's name as the Wallet app shows it; the payment shortcut uses it to find the card), shown next to the card's last four digits. Input is trimmed, internal spaces collapsed, capped at 64 characters, and empty clears it (`normalizeWalletName`); a name another card in the ledger already uses (23505) reads "Another card already uses this Wallet name". Saving refreshes every ledger view, since the server re-processes waiting Wallet payments. Owners only; viewers and View only ledgers see the name but no edit control.
- **add** Review: an unknown-card review for a Wallet payment shows the pass name and links to Cards ("Set this as a card's Wallet name") instead of offering to register a card number (which the server refuses for Wallet rows); "Not a card transaction" and Dismiss still work. The card is labelled **Wallet payment** (`walletPassNameOf`, unit-tested).

### iOS

- **add** **Log Card Payment** App Intent and App Shortcut (`LogCardPaymentIntent`: Amount as a currency amount, Merchant, Card), run by a Shortcuts Transaction automation without opening the app. LedgerKit `WalletCapture` checks and normalises the payment on the phone (amount as `Decimal`, sent as a decimal string) and `WalletIntake` mirrors `SMSIntake`: same "SMS go to" ledger, same result wording, and an unknown card names the card and points to Settings → Card names.
- **change** The SMS outbox carries both kinds (`OutboxItem`: `sms` / `wallet`) and flushes each profile's SMS to `ingest_sms` and payments to `ingest_wallet_transactions`, so a payment made offline is sent when a connection is back. Queued files written before this decode as SMS. `Outbox` split into `Outbox+Flush.swift` and `OutboxEntry.swift`.
- **add** Settings → **Card names for payment shortcut**: each card (bank logo, last 4) with its editable `cards.wallet_name` for owners, read-only on view-only ledgers; a name another card has is refused in words (23505). LedgerKit `LedgerCard`, `cards(profileCode:)`, `updateCardWalletName(cardCode:name:)`, `CardWalletNamesModel`.

### Docs

- **change** ARCHITECTURE §3 (`sms_messages.source`, `cards.wallet_name`) and §4 Wallet path.
- **change** `apps/ios/README.md` Card payment capture: the Shortcuts Transaction automation setup and card names.

## Backlog batch 1: invites, OTP filter, budgets, rule editor, iOS contrast and VoiceOver — 2026-10-13

### Backend (Supabase)

- **change** `20261012210407_budget_status_is_effective`: `budget_status` returns `is_effective`, `effective_from` and `effective_to`, and takes `p_include_inactive` to also list replaced, upcoming and ended budgets. The two-argument call returns the same rows; a non-member now gets 42501 (WEB-28).
- **fix** `20261012212011_sms_otp_filter`: `ingest_sms` drops OTPs with `private.sms_otp_pattern()`, the same string the iOS filter uses. It now also catches "Use 482913 as the code…", "authentication code", "secure code", 3-D Secure passwords, "never share this code" and Arabic رمز التحقق / كلمة المرور / رمز لمرة واحدة. A bare "one time" in Arabic or English is not enough (a one-off fee alert says it). Run read-only against every production SMS: 0 of 123 matched (IOS-10).

### Web

- **add** Settings → Members: "Invite" goes through the `member-invite` Edge Function, so someone without an account gets the invite email; "Resend invite" on pending members, with clear messages for the 10-minute cooldown, an already-active account and the rate limits (NEW-1r). Edge Function errors keep their code and status through one helper (`functionError`), which statement upload uses too.
- **fix** Live updates no longer die when the profile switches A→B→A or under StrictMode: each Realtime subscription (ledger and document events) uses its own channel topic (WEB-09).
- **fix** "Apply to every transaction from this merchant" clears after each pick and whenever the picker closes (WEB-12).
- **fix** The rule editor shows the server's reason when it rejects a rule (22023) and disables Save until it is fixed; other preview failures offer Try again and leave Save to the server (WEB-13).
- **fix** Budgets load from `budget_status` alone and split on the server's `is_effective` (no client copy of the selection rule); a failed load shows an error with a retry, not an empty state (WEB-28).
- **change** The tokens contrast test also checks the iOS app's text and icon pairs (`tokens.json#contrast.ios`) in both themes; no colour changed (IOS-19r).

### iOS

- **fix** The SMS OTP filter is the server's pattern character for character, pinned by the shared fixture in pgTAP `38` and `SMSOTPParityTests`; every SMS template example is must-send (IOS-10).
- **fix** Caption text (Top merchants ranks, "Category from …", the config hint) uses `muted`, not `subtle`; `PaletteUsageTests` enforces it (IOS-19r).
- **fix** VoiceOver reads the Overview hero as one sentence, "October spend, posted so far, 860 dirhams" (IOS-20r).

### Docs

- **change** BACKLOG: batch 1 done (8 items), new rows WEB-13r and WEB-28i; 04/05 Fix status; PRODUCTION invite runbook; ARCHITECTURE SMS path; README Budgets; CLAUDE.md §13 guards for the palette and OTP parity tests.

## Archive instead of delete; a read-only super admin — 2026-10-12

### Backend (Supabase)

- **change** `20261012180000_archive_and_super_admin`: queue messages are archived, never deleted. `queue_delete`, `queue_to_dlq`, `requeue_dlq` and `drain_dlq` use `pgmq.archive` (same signatures), so every message and its `dlq_reason` stay in `pgmq.a_<queue>`.
- **change** `delete_profile` archives the profile (`profiles.archived_at`, `archived_by`, `archive_state`). Nothing cascades: data, PDFs and Vault secrets stay, and no PDFs are queued for `storage_cleanup`. Its active service tokens are revoked and its mailboxes disabled. Archived profiles drop out of `my_profile_codes`, `my_owned_profile_codes` and `assert_member`, so no client sees them. **add** `restore_profile` (service role) undoes exactly what archiving turned off.
- **add** Super admin: `private.super_admins` (seeded with `h_abbasi97@hotmail.com`, matched once the email is confirmed) and `authz.is_super_admin()`. A super admin reads every active profile (data, members, secret names, tokens) through `my_profile_codes` and member-level RPCs, and writes only where it is an owner, enforced by RLS and owner checks. pgTAP `36_archive_and_super_admin`; `17_db_identity_and_legacy` asserts archiving and restore.

### Web

- **change** The ledger list reads `profiles` (RLS: your ledgers, or every active one for a super admin) with your own membership embedded. Ledgers you are not a member of are listed under **Other ledgers** as **View only**, and every edit control is off there (`isOwner` is false). Onboarding and the default ledger consider only your memberships.

### iOS

- **change** LedgerKit `ProfileAccess` (owner / viewer / view only) drives `canWrite` and the ledger order. The ledger picker and Settings mark ledgers you are not a member of **View only**; category editing in Activity and statement detail, and dismissing insights, now need an owner (the server already refused them).

### Docs

- **change** ARCHITECTURE §3/§8, PRODUCTION runbook and README RPC table: archive semantics, `restore_profile`, super admin.

## Web smoke reads the deployed commit off production — 2026-10-12

### Web

- **fix** Each build stamps its commit in `<meta name="ledger-build">` (`vite.config.ts`, from `VERCEL_GIT_COMMIT_SHA`). `web-smoke.yml` now waits until production serves that commit or a newer one containing it, instead of waiting for a Vercel GitHub Deployment or status: Vercel often posts neither (`a346956`, `f683280` shipped with none), so the job waited 9 minutes and failed on deploys that had shipped. A "Vercel" failure/error status still fails fast; production not serving the push after 9 minutes still fails. Lesson in `tasks/lessons.md`.

## SMS fallback skips messages without a sender — 2026-10-12

### Backend (Supabase)

- **fix** `worker` `sms_fallback`: a message with an empty sender (a hand-typed test, or a Shortcut not passing Sender) is skipped before the LLM call and stays `unparsed` for review. It used to call the model, fail `propose_sms_template` (22023: every template is anchored on the bank's senders) and dead-letter, alerting Sentry (`sms_fallback_dlq`).

## SMS alerts from Emirates Islamic and Wio become transactions — 2026-10-12

### Backend (Supabase)

- **add** `20261012170000_sms_templates_eib_wio`: templates from real alerts. Emirates Islamic (sender `EI SMS`): the multi-line "Credit Card Purchase / Card Ending / At / Amount / Date / Available Limit" alert as a purchase; the mini statement, Apple Wallet enrol/disable and wallet OTP prompt, and Smart Pass / account-access notices as ignored. Wio (sender `WioPersonal`): "Payment of AED … was done at … using your Wio Personal card NNNN with Credit money" as a purchase (no date in the alert, so it is dated at received_at; whole-dirham amounts parse) and "added to Apple Pay" as ignored; a payment from another Wio balance has no sample yet and stays `unparsed` for the LLM fallback. Emirates NBD: the ENBD X account-recovery notice as ignored. `banks.sms_senders` becomes `{EI SMS}` for EIB and `{WioPersonal}` for Wio (guarded). Inserting the templates re-processes those senders' recent unparsed messages. pgTAP `35_sms_templates_eib_wio`.

### Docs

- **change** ARCHITECTURE §9 and the iOS README: the "Card" automation covers EIB and Wio too; Wio writes "card" in lower case, so it relies on Shortcuts' "contains" ignoring case (still to be checked on a device).

## Card budgets: a monthly limit for one card, or one card and one category — 2026-10-12

### Backend (Supabase)

- **add** Migration `card_budgets`: `budgets.account_code` (optional, composite FK to the profile's own accounts, cascades with the account). A budget with a card counts only that card's spend in the month (all of it, or one category's); without one it counts every card, as before. The unique scope is now card × category × start month. `budget_status` returns `account_code`, `account_name` (nickname, else "BANK · product") and `bank_code`, and narrows spend by card. `budget_risk` insights key on the card too (an all-cards budget keeps its old key) and name it ("Dining on Daily card budget at risk"). `merge_accounts` moves a merged card's budgets unless the surviving card already has one for that scope. pgTAP `34_card_budgets`. DB types regenerated.

### Web

- **add** Budgets: the budget dialog has an optional **Card** picker ("All cards" by default, then each active card with its logo and last digits). A card budget's card reads "Daily card" (all its spending) or "Dining · Daily card" (`budgetTitle`), with the bank logo; only the every-card total is the full-width hero. Budgets not active this month name the card too.

### iOS

- **add** Budgets: the edit sheet has an optional **Card** picker before Category ("All cards", then each active card; a closed card stays offered when it is the budget's own). Card budgets show the bank logo and read "Daily card" or "Dining · Daily card" (`BudgetScope.title`, same rule as the web), on the month's cards, the not-active list, the delete prompt, VoiceOver and the Insights budgets card. Card names follow the server's `AccountLabel.make`. Cards load from `public.accounts`; if that fails the form still offers "All cards".

## Docs: Wio is a credit card that pays other credit cards — 2026-10-12

### Docs

- **change** Parser, contract and ARCHITECTURE wording: Wio Personal is a credit card only (no debit card); its "ENBD payment" / "EIB AZ payment" rows are the card paying other credit cards from its credit line. "Debit" in those notes is the ledger direction of a charge, never a debit card.

## Card transfers: Wio's payments onto other cards are linked to those cards' credits — 2026-10-12

### Backend (Supabase)

- **add** Migration `card_transfers`: `public.card_transfers` pairs a debit `payment` on one card (Wio paying a card from its credit line: "ENBD payment", "EIB AZ payment") with the credit `payment` it became on the paid card ("TRANSFER PAYMENT RECEIVED THANK YOU", "INWARD IPP CC"). `private.link_card_transfer` runs from a trigger on every insert/update of a payment's matching facts: same AED amount, opposite directions, different accounts, at most 3 days apart, neither side already linked, and each the other's only candidate (an ambiguous pair stays unlinked). A side that is voided or orphaned drops its link and its partner looks again. `transactions.related_txn_code` keeps meaning "reverses". `v_transactions` gains `transfer_txn_code`, `transfer_bank_code` and `transfer_card_last4`. Backfilled for every profile. RLS: members read, no client writes (privilege matrix updated). Spend is unchanged (payments were never spend). pgTAP `33_card_transfers`. DB types regenerated.

### Web

- **add** Activity rows of a card transfer say "Paid to EIB •6177" (the payer's debit) or "From WIO •2010" (the paid card's credit); the drawer's "Card transfer" section opens the other side.

### iOS

- **add** The same "Paid to" / "From" line on Activity rows and in the category sheet's header (`LedgerTransaction.transferPeer`).

## Pushing from a worktree builds the iOS release again — 2026-10-12

### Docs

- **fix** Tooling: `scripts/hooks/pre-push` unsets `GIT_DIR` (and `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`), which git exports to hooks. In a worktree it pointed every child `git` at `.git/worktrees/<name>`, so SwiftPM's package checkouts in `swift test`, `xcodebuild` and `publish-build.sh` failed with "unable to read tree" and a push to `main` couldn't stage its TestFlight build. Lesson in `tasks/lessons.md`.

## App Review can sign in: a demo account with a synthetic ledger — 2026-10-12

### Backend (Supabase)

- **add** `20261012130000_review_demo_ledger`: `private.create_review_demo(user_id, today)` creates the `app-review` ledger, makes that user its only owner (refusing a user who already has a ledger, a second demo ledger and any client role), and `private.seed_review_demo` fills it with synthetic data dated relative to `today` through the real ingest paths: two cards (ADCB •4821, FAB •7310), six reconciled statements each via `ingest_parsed_document`, alerts in the formats the production ADCB/FAB templates already parse via `ingest_sms` (about 40% of billed purchases, then everything after each card's last statement stays pending), profile category rules, budgets, recurring series and insights. Nothing global is written beyond merchants; no SMS templates, no parse or LLM-fallback jobs are left behind. Run as `postgres` by `scripts/cutover/create-review-demo.sh` (Auth admin API user with a generated password, credentials in the gitignored `.env.review-demo`). pgTAP `32_review_demo`.

### iOS

- **fix** Beta App Review rejected builds 3 and 6 under Guideline 2.1(a): the reviewer could not sign in (email code or passkey only). The sign-in screen gains *Sign in with a password* (email + password, back to *Use an email code instead*); `SessionStore.signIn(email:password:)` now ships in Release, with `canSubmitPassword` deciding when Sign in is enabled (`PasswordSignInTests`). Only the App Review demo account has a password, so the form signs no one else in.
- **add** `testflight-distribute.mjs --review-account` saves `LEDGER_REVIEW_EMAIL` / `LEDGER_REVIEW_PASSWORD` in Beta App Review Information ("Sign-in required" on, notes pointing at the password option); the password is never printed. A normal run now refuses to submit a build for Beta App Review while no demo account is set, instead of submitting one that is bound to bounce.

### Docs

- **change** PRODUCTION §2.2 and §7 step 5 (the review account), ARCHITECTURE §8, README (iPhone screens, TestFlight env), `supabase/CLAUDE.md` and `apps/ios/CLAUDE.md` auth facts; lesson in `tasks/lessons.md`.

## Wio Bank credit statements — 2026-10-12

### Parser

- **add** WIO (`2026.10.11`): Wio Bank's "Credit Statement" (Wio Personal credit card). Rows are one date, a reference, the description, the card (`****2010`) and a signed AED amount (negative is spend). A foreign purchase is followed by `Rate: 3.70 (AED/USD)` and its own `Foreign Exchange Fee` row (`fee`); the foreign amount is never printed and the rate has two decimals (EGP prints 0.07), so every line stays AED. Rows without a card that end in `payment` (`ENBD payment`, `EIB AZ payment`, `Mashreq payment`) pay another bank's card from the Wio credit line: debit `payment`, kept out of spend. Totals come from the "Account summary" (opening, purchases + interest + late fee + FX charges, payments and credits, signed closing balance) only when it adds up, plus the credit limit, minimum due and due date; the Arabic labels of the bilingual layout (from Sep 2026) are dropped before matching. Detection: "Wio, PJSC" / "Wio Bank" outside transaction rows and the "Credit Statement … Tot. interest and fees" header, so rows naming ENBD or Mashreq don't vote. Tejasvie's Jun–Sep 2026 statements (67, 101, 110 and 66 rows) all reconcile line for line. Synthetic case `wio_statement`.

### Backend (Supabase)

- **add** Migration `wio_bank`: `public.banks` row `WIO` "Wio Bank" (`logo_path = 'WIO.png'`, no SMS sender: Wio alerts are app notifications) and its `private.bank_fx_fees` markup, 0.75%: the scheme rate alone (AED/USD 3.70 against the 3.6725 peg), because Wio bills its 2% FX fee as a separate statement row. Guarded inserts. pgTAP `05_fx_rates` and `20_statement_rpcs_and_logos` cover it.

### iOS

- **add** The Wio logo is bundled (`Bank/WIO`): wio.io's own square icon, an opaque purple tile, so it needs no light chip in dark mode.

### Docs

- **add** `assets/banks/WIO.png`: wio.io's published `logo.png`, unmodified (an earlier draft re-rendered the wordmark; a logo is downloaded, never drawn), and its README row; contract notes for WIO rows and totals; ARCHITECTURE `banks`, README, PRODUCTION logo upload loop.

## Emirates NBD dnata Platinum: foreign rows and Credit Shield charges — 2026-10-12

### Parser

- **fix** ENBD (`2026.10.10`): a foreign row ("*RL360 DOUGLAS GBR 2,000.00 USD 7,574.25", then "(1 AED = USD 0.26405)") was an AED line whose description kept the original amount and currency, and its country was read as the currency. The rate line now confirms the currency: the description ends at the merchant and place, the line carries the original amount, currency and rate (AED per unit), and the country comes from the place. The Credit Shield premium and its "VAT ON INSURANCE" row are fees (the summary counts them under Interest/Other Charges), not purchases. amount_aed and the legacy fingerprint are unchanged (golden parity delta `2026.10.10`). Tejasvie's four dnata Platinum statements (card 1287, May and Jul–Sep 2026) reconcile. Synthetic case `enbd_fx_and_charges`.
- **fix** `tests/synthetic/versions.json` is written in release order: sorted keys put `2026.10.10` before `2026.10.2`, which failed the "ends with the current version" check.

## Emirates Islamic: every month and both cards parse — 2026-10-12

### Parser

- **fix** EIB (`2026.10.9`): 5 of Tejasvie's 10 EIB statements (two primary cards: Amazon World 6177 and RTA 4557) still failed or came back empty, because the bilingual header extracts in a different order from month to month. The card number is now also read from the name line ("... 5424 XXXX XXXX 6177 PAGE 1 OF 3") when "Card Account Number.:" stands alone, the period end is read with or without its "To:" label in front, and the card holder from the three lines after "Statement of Card Account". A month with no activity prints no OPENING BALANCE line and no card section: its opening balance is its closing balance (the balance carried over), and the warning says "no activity" instead of "no rows matched". All 10 reconcile; each card gets its own account (an unknown last4 on a statement creates one). Synthetic case `eib_card_account_quiet`.

## Gmail ingest runs on a Google OAuth client in the parser's GCP project — 2026-10-12

### Docs

- **change** PRODUCTION §5: the Gmail OAuth client `ledger-gmail` now lives in `credit-card-scraper-ht`, beside the `gmail-statements` topic (Gmail's watch rejected the topic for the legacy client: `GMAIL_400`). The rebuild steps say to leave the home page and logo empty and keep the app in *Testing* (publishing needs a verified domain), and the weekly refresh-token renewal is written down. §2.5's secrets table shows what is set today, with the real push service account and topic names; `GMAIL_SENTRY_ALERTS=on` in production.

## Emirates Islamic statements parse — 2026-10-12

### Parser

- **fix** EIB (`2026.10.8`): the parser was written for the Emirates NBD template without a real EIB sample, so the first real statement (an Amazon World Mastercard) failed with `UNSUPPORTED_LAYOUT`. `banks/eib.py` now reads EIB's "Statement of Card Account" layout: the period on two lines ("From:1st Sep 2026" / "To:30th Sep 2026"), "DD MON DD MON" rows with the post date first and the year taken from the period end (Dec/Jan safe), a foreign row's original amount and currency confirmed by the next "*(1 AED = EGP 13.34128)" line (stored as AED per unit), primary and supplementary card sections, and a merchant credit as a refund (only a row that says PAYMENT is a payment; EIB has no legacy data to keep). `totals.py` reads the opening balance and the "Card Limit ... Current Balance (AED)" row (closing balance, minimum due, due date, credit limit). The ENBD-template path stays as the fallback. Synthetic case `eib_card_account`; the real statement's 18 lines reconcile to its printed 61.79.

## The guard refuses recursive searches over secret files — 2026-10-12

### Docs

- **fix** Claude Code tooling: `.claude/hooks/guard.py` denied printing a secret file named on the command line but not a recursive search over the directory holding it, so `grep -rniE "gmail|oauth" supabase/functions …` printed values from `supabase/functions/.env` and `.env.production`. New `check_recursive_search` denies `grep -r`/`-R`, `rg -uu` (or `--no-ignore` with `--hidden`) and `find … -exec cat`/`| xargs grep` when a search root holds a gitignored secret file (`.env*` except `.env.example`, `.env.cutover`, `Secrets*.xcconfig`; the §11.4 directories count even on a clean clone) that the command does not exclude; its message points at `rg PATTERN DIR` or `--exclude='.env*'`. Plain `rg`, `grep -rl`/`-c`, and searches of directories without secrets stay allowed; quoted `|` in a pattern and heredoc bodies are not mistaken for commands. Cases in `guard_test.py`; lesson in `tasks/lessons.md`.
- **add** CI tooling: `guard_test.py` runs in the `tooling` job and the pre-push tooling checks, which now also trigger on `.claude/hooks/**` (docs/ci-cd.md §1.1).

## Outstanding balance per card; orphaned duplicates out of the net — 2026-10-12

### Backend (Supabase)

- **fix** `20261012043206_outstanding_balance`: the Activity net for the main profile read AED 796.13 in credit while the cards owed about AED 3,568. The 2026-10-11 FAB re-parse left 110 orphaned transactions beside their re-created twins (net AED -2,996.20); their reviews were dismissed, which closed the review but left the rows counted. `activity_summary` now counts pending and posted rows only, like `v_spend`; dismissing an orphaned-transaction review voids the transaction (`orphan_dismissed`); new `private.void_orphan_duplicates()` voids orphans with a live twin on the same statement (same date, direction, kind, AED amount, description), paired one to one, skipping annotated rows, and runs once here (production: the 110 FAB rows).
- **add** `public.v_account_balances` (security invoker): what each card owes now, anchored on the latest printed balance, which a transaction sum cannot know (ENBD's first statement opened at 404.07, FAB's at 64.38): the latest statement's closing balance plus live activity not on it, or for SIB the replacement card's "BALANCE MIGRATION" (the old card's balance) plus activity from that day. `overview` gains per-account `outstanding_aed`, `balance_anchor`, `balance_anchor_date`, `balance_has_estimate`, `balance_unpriced_count`, and profile `outstanding`, `outstanding_complete`, `outstanding_has_estimate`. Production on 2026-10-12: ADCB -0.84, ENBD 83.78, FAB 515.26, SIB 2,969.79. pgTAP `31_outstanding_balance`; `11_privileges` adds the view's SELECT.

### Web

- **add** Overview → Cards: "Owed now" per card (with what it is anchored on: "Statement of 1 Oct + activity since", "Card replaced 15 Sep + activity since") and the total over active cards; a credit balance reads "AED 0.84 in credit", estimates "≈", and the total says when it excludes unpriced charges or a card has no anchor. Pure helpers in `lib/balances.ts`, unit-tested.
- **change** Review → Orphaned transactions: the button reads "Void transaction" (dismissing now voids it) and the help says orphans count in no total.

### iOS

- **add** Overview → Cards: "Owed now" for the active cards in total, and per card with what it is anchored on ("Statement of 25 Sep + activity since", "Card replaced 15 Sep + activity since"), from `overview`'s server-computed balances. A credit balance reads "AED 0.84 in credit", estimates "≈", and the total says when it excludes unpriced charges or a card has no anchor. A server without the fields shows nothing. Wording in LedgerKit `OutstandingBalance`, mirroring the web's `lib/balances.ts`; `OutstandingBalanceTests`.
- **change** Review → Orphaned transactions: the button reads "Void transaction" (dismissing now voids it) instead of "Dismiss" with a "More options are on the web" note, and the help says orphans count in no total.

### Docs

- **change** ARCHITECTURE §6: one definition of what a card owes; orphaned rows count in no total. README: the Overview screen row.

## A re-parse after an account merge no longer re-creates transactions — 2026-10-11

### Backend (Supabase)

- **fix** `20261011172405_merge_accounts_rekey_lines`: `private.merge_accounts` re-keys the lines it moves. `line_key` hashes the account, and `20261010001400` moved the FAB 2777 account's lines onto the kept account without re-keying them, so re-parsing those documents for parser 2026.10.7 superseded 115 lines and orphaned their transactions, re-creating them with the same facts (no manual category, note or exclusion was on any of them). New `private.statement_line_key` is ingest's expression; masked lines hash their original text, as ingest did. Production keys already match after the re-parse, so no backfill. pgTAP `28_merge_accounts` (re-parse after a merge supersedes and adds nothing; every key equals the helper's).

## ADCB FX markup is 2.99% + scheme — 2026-10-11

### Backend (Supabase)

- **fix** `20261011171500_adcb_fx_markup`: ADCB's markup is 4.1744% ((1 + 2.99%) × 1.0115 − 1), not 2.99% all-in. Checked against production's billed foreign rows: ADCB's 20 USD purchases ran at peg × 1.0402–1.0420 (median 1.0418), while FAB USD (51 rows, 3.79%) and Mashreq USD (4 rows, 4.07%) already matched their markups. Guarded update; ADCB estimates re-derived. pgTAP `05_fx_rates`, `02_ledger`.

## FX estimates use the rate of the transaction's own date — 2026-10-11

### Backend (Supabase)

- **fix** `20261011170000_fx_rate_history`: estimates used the newest market rate (`fx_rates` is overwritten nightly), so the SIB INR 28,400.00 purchase posted 2026-10-03 (billed AED 1,123.72) read AED 1,116.32 a week later. New `private.fx_rate_history (currency, as_of)` keeps every daily rate; `upsert_fx_rates` writes each nightly update there too; `private.market_rate(currency, on_date)` is the latest row on or before the date, else `fx_rates`. `private.estimate_fx(profile, currency, bank, on_date)` takes the line's posting date (else txn date) or the SMS's Dubai date; the order (bank statement rate → USD peg / market × bank markup) is unchanged and the three-argument overload is dropped. Backfill: 6,360 daily rates 2025-01-11 .. 2026-10-10 for EGP EUR GBP INR JPY KES KWD MYR PKR THB (every non-AED, non-USD currency in production) from the fawazahmed0 currency-api, inverted to AED per unit; the SIB case becomes AED 1,124.23. Every estimate is re-derived once. pgTAP `05_fx_rates`.

### Docs

- **change** CLAUDE.md §11.1, supabase/CLAUDE.md and lessons: the Supabase MCP connector reaches this project when connected to its organisation (check `list_projects`); read-only `execute_sql` is inspection.

## FAB VAT rows are AED; FX estimates learn only from purchase rates — 2026-10-11

### Parser

- **fix** 2026.10.7: a FAB "VAT ON SERVICE CHARGES" row is an AED line. FAB prints it under each foreign purchase with that purchase's currency and original amount beside the AED VAT ("KES 5000.00 … 0.27"); up to 2026.10.6 it became a KES 5,000.00 line at 0.000054 AED/KES (124 such lines in production). `amount_aed` and the legacy fingerprint are unchanged. Synthetic FAB case gains a VAT row; golden parity allows the delta (41 FAB PDFs).

### Backend (Supabase)

- **fix** `20261011163506_fx_estimate_purchase_rates`: `private.estimate_fx` step 1 (the bank's own statement rate) reads only current `purchase` / `refund` / `cash_advance` lines, latest by date then `line_code`. A FAB VAT row's rate (0.00689655 AED/USD) priced SIB USD history rows (USD 249.99 → AED 1.72) and, with per-bank estimates, would have priced FAB's own pending USD SMS. A superseded line no longer counts.
- **fix** `refresh_transaction`: a posted line without a printed AED amount (SIB history rows) stores the rate its estimate used in `fx_rate`, as a pending SMS row does; it was null. Every estimate is re-derived once. pgTAP `05_fx_rates`.

## Destructive migration guard ignores function bodies — 2026-10-11

### Docs

- **fix** CI tooling: the deploy's destructive guard (`scripts/ci/check-migrations.sh`) now flags only `DROP TABLE/SCHEMA/COLUMN`, `TRUNCATE` and `DELETE FROM` that run when a migration is applied. `scripts/ci/sql_executed_text.py` blanks comments and `create function|procedure` bodies first (line numbers kept); `DO` blocks, cron commands and string literals still count. `20261011000100_bank_fx_fees` was blocked only because it redefines `refresh_transaction` and `match_sms`, whose bodies delete when called. Over all migrations: 45 matches before, 2 real ones after (a top-level `drop table _seed_fix` and the cron history purge). New mode `check-migrations.sh destructive <file>…`; tests `scripts/ci/sql_executed_text_test.py` (CI tooling job, pre-push). docs/ci-cd.md and supabase/CLAUDE.md updated.

## FX estimates are per bank, with each bank's FX markup — 2026-10-11

### Backend (Supabase)

- **fix** `20261011000100_bank_fx_fees`: `private.estimate_fx(profile, currency, bank)` no longer uses another bank's statement rate. An SIB INR 28,400.00 purchase showed AED 1,147.83 (another bank's marked-up INR rate on the same profile) while SIB billed AED 1,123.72. Order now: AED = 1; the bank's own latest statement rate; else the USD peg or `fx_rates` mid rate × (1 + `private.bank_fx_fees.markup`). The two-argument overload is dropped; `new_transaction_from_line`/`_sms`, `refresh_transaction` and `match_sms` pass the bank (bodies otherwise unchanged). Every existing estimate (pending SMS and posted SIB history rows) is re-derived once. pgTAP `05_fx_rates` (also: every bank has a markup), `02_ledger`.
- **feat** All-in FX markups from each bank's published fee: a fee on top of scheme charges is (1 + fee) × 1.0115 − 1 (Visa/Mastercard ≈ 1.15%, as the ENBD and Emirates Islamic KFS state); a margin quoted on the wholesale rate including processing fees is taken as is. SIB 2.50% + scheme → 3.6788% (reproduces the real bill: AED 1,123.69 vs 1,123.72); FAB Cashback Mastercard World 2.61% (2.49% + VAT) + scheme → 3.79%; ENBD noon One Visa 1.99% + scheme → 3.1629%; Emirates Islamic 2.54% + scheme → 3.7192%; Mashreq 2.89% + scheme → 4.0732%; ADCB Infinite Visa 2.99% all-in. Per bank, not per product: ADCB Traveller (0%) and EIB Emarati/Skywards Black (2.30%) are over-estimated until a statement prints their rate.

## iOS: SMS saved with no data are sent once a connection is back — 2026-10-10

### iOS

- **fix** Being offline (no mobile data, airplane mode, roaming off, DNS/connect failure, timeout: `LedgerAPIError.isUnreachable`) no longer uses up the outbox's 8 attempts, so a day without data no longer parks messages under Settings → Not sent. It stops the flush (other ledgers would fail too) and the message waits; anything unsent 7 days after capture (`Outbox.maxAge`) is parked, except while signed out. Server outages keep the 8-attempt cap. Tests `OutboxOfflineTests`; `OutboxTests` backoff case now uses a 503.
- **feat** Waiting messages are sent without opening the app. LedgerKit `OutboxSync`: `pathChanged` force-sends the queue when an `NWPathMonitor` reports the connection is back (app or intent process), and `plan` decides the background request. The app registers a `BGProcessingTask` requiring network connectivity (`com.hussu97.ledger.outbox-send`) and a `BGAppRefreshTask` (`com.hussu97.ledger.outbox-refresh`), submitted when the intent queues a message and when the app goes to the background, resubmitted after each run while anything waits. `project.yml`/Info.plist: `UIBackgroundModes` fetch + processing, `BGTaskSchedulerPermittedIdentifiers` (a test checks they match the code). The `received_at` captured when the Shortcut ran is unchanged.

## LLM categorisation runs at 18:00 UTC — 2026-10-10

### Backend (Supabase)

- **change** `20261010001700_llm_enqueue_schedule`: `ledger-llm-enqueue` runs at 18:00 UTC (22:00 Dubai) instead of 22:30 UTC, so the day's new merchants are categorised the same evening. ARCHITECTURE.md and PRODUCTION.md cron tables updated.

## iOS: Budgets tab, Statements in Settings — 2026-10-09

### iOS

- **feat** A **Budgets** tab takes the Statements tab's place (tabs: Overview, Activity, Insights, Budgets, Settings), at parity with the web Budgets page: the shared month switcher, one card per `budget_status` row (spent of limit, meter, "% used", "On pace for …" / "Month closed", Over chip; every figure the server's), a "Not active in <month>" list ("Starts …", "Ended …", "Replaced by a newer budget"), and create / edit / delete on `public.budgets` the way the web writes it (all spending or a spend/fee category, amount sent as a decimal string, start month and optional end month; owners only, viewers see a note). Loading, failed and empty ("No budgets yet" + Create a budget / "No budgets apply to …") states. Insights' budgets card gains **See all budgets**, which switches to the tab, and refreshes after a budget is saved. LedgerKit: `Budget`, `BudgetDraft` (the web's `validateBudget` rules and wording, month choices), `BudgetCategoryChoice`, `BudgetStatus.tone(isCurrentMonth:)` (the web's `budgetTone`: over = danger, 80%+ or overspend pace this month = warning), `BudgetsModel`, `LedgerTab` / `TabRouter`; `LedgerAPI.budgets` / `saveBudget` / `deleteBudget`. Tests `BudgetsTests`.
- **change** Statements moved to **Settings → Cards & statements → Statements**, unchanged: cycles and statement detail, uploads and their processing logs, the document picker, and PDFs waiting from the share sheet (the row shows the waiting count). The share sheet's confirmation now says "watch progress in Bank Ledger → Settings → Statements". No deep link, notification or App Shortcut selected the Statements tab, so nothing else needed re-routing.

## Insights spending filters — 2026-10-09

### Backend (Supabase)

- **feat** `20261010001600_spend_filters`: `spend_series` and `spend_breakdown` take optional `p_category_codes`, `p_bank_codes`, `p_card_codes` (text arrays; `'__uncategorized__'` = no category) and `p_q` (merchant name OR description, cleaned like the Activity search). One definition, `private.filtered_spend`, over `v_spend`, so chart and totals agree. Both functions are dropped and recreated (an overload would make PostgREST's named calls ambiguous); `spend_series` is now SECURITY DEFINER with `assert_member` and an explicit profile filter, like `spend_breakdown`, since clients cannot use `private`. pgTAP `30_spend_filters`

### Web

- **feat** Insights → Trends "Spending over time" has a filter row: debounced merchant/description search and multi-select **Categories** (with Uncategorised), **Banks** (only banks you hold an account with) and **Cards** (`FAB •2777`, supplementary hinted), with removable chips and Clear. Filters live in the URL (`?cat=&bank=&card=` comma-joined codes, `?q=`), survive range / group / bucket changes, and every group-by and bucket size charts only the filtered spend (server-side, `spend_series` / `spend_breakdown`). A combination with no spend says "No spending matches these filters" with Clear filters. `useSpendSeries` / `useSpendBreakdown` / `SpendSplitChart` take optional filters (in the query key), so Overview's monthly bars are unchanged. Tests: `trend-filters.test.ts` (codec), `trend-filter-options.test.ts` (options, chips), `spendFilterArgs` in `analytics.test.ts`.

### iOS

- **feat** Insights → Monthly spend has a **Filter** button (badge = filters on) opening a sheet: merchant/description search and multi-select Categories (spend categories plus Uncategorised), Banks and Cards, with Clear and Done. The card shows the active filter (`Dining, Grocery · FAB · •2777 · “careem”`) with Clear; None, Category, Bank and Merchant all chart only the filtered spend, and an empty result says "No spending matches these filters in this period." LedgerKit `SpendFilter` (RPC params, summary), `SpendFilterOptions` (from `filter_meta`); `LedgerAPI.spendSeries`/`spendBreakdown` take a filter (unfiltered overloads kept); `SpendSplitModel` loads filtered `spend_series` for None and clears the filter on a ledger switch. Tests `SpendFilterTests`.

## Web smoke waits on Vercel's commit status too — 2026-10-09

### Docs

- **ci** `web-smoke.yml` waited for a GitHub Deployment from Vercel that Vercel did not create for build 8's counter commit (`12cfe0f`, deployed and reported only as a `Vercel` commit status), so the job ran into its 10-minute timeout and was cancelled. It now accepts either the Production Deployment or the `Vercel` commit status (`statuses: read`), and its wait (9 min) fits inside the job timeout, so a missing deploy fails with a message.
- **data** The emptied FAB account left by `merge_accounts` (closed, no cards, statements or transactions) was deleted in production.

## FAB card type — 2026-10-09

### Parser

- **fix** FAB's card type came from the header's product cell, which shares a text line with the address column, so every FAB statement read `1101 BUHAIRAH TOWER CASHBACK CARD` (the street address glued to the product). The type now comes from the `Main Card : 5492 84** **** 2777 CASHBACK CARD` line; the header is the fallback. The synthetic FAB case prints an address on the product line, as the real layout does. 2026.10.6

### Backend (Supabase)

- **data** Production accounts renamed: FAB → nickname "FAB Cashback Card", product "Cashback Card"; ADCB → "ADCB Infinite Card", product "Infinite Card" (ingest sets `product_name` only when it creates an account, so this sticks).

## Activity summary — 2026-10-09

### Backend (Supabase)

- **feat** `20261010001500_activity_summary`: `public.activity_summary(profile, from, to, account, card, category, uncategorized, status, source, q)` returns `txn_count`, `net_aed` (debits − credits, void excluded, decimal string), `unpriced_count`, `has_estimate`, `earliest_date`, `latest_date` over `v_transactions` with the Activity list's filters. Search is description OR merchant name, cleaned by `private.activity_search_pattern` exactly as the clients clean it for PostgREST. pgTAP `29_activity_summary`

### Web

- **feat** Activity shows a summary line above the list for the current search and filters: transaction count, net AED (debits minus credits, void excluded), and the earliest–latest transaction date, all from `activity_summary` (`useActivitySummary`, `activitySummaryArgs`, `components/activity/summary.tsx`). An "AED estimated" badge marks a net that includes estimated FX rates, and "excl. N without AED amount" counts rows not yet priced. Loading, failed and empty (no date range) states. It replaces the header's count
- **fix** The Activity search matched the description only; it now matches description OR merchant name through a PostgREST `or` filter, with the term cleaned exactly as iOS `ActivityQuery.sanitizedSearch` and the RPC clean it (`sanitizedSearch`, `searchOrFilter`; `ilikePattern` removed). Placeholder "Search description or merchant"
- **test** `activitySummaryArgs`, `sanitizedSearch`/`searchOrFilter`, the `or` list filter, `formatDateSpan`

### iOS

- **feat** Activity shows a header row above the list for the current search and filters: transaction count, net AED (a net credit reads "+ AED …", "≈" when an FX estimate is in the sum), the earliest–latest transaction date ("1 Jun 2026 – 8 Oct 2026", one date when equal) and "excl. N without AED amount" when some rows are unpriced, all from `activity_summary` (`LedgerAPI.activitySummary`, `ActivityQuery.summaryParams`, `ActivitySummaryHeader`). It loads with the first page, on new filters or search, on pull-to-refresh, on realtime refresh and after a recategorise; a redacted placeholder shows while the first answer for these filters loads, and a failed summary hides the header without touching the list (`ActivityModel.summaryDisplay`, `ActivitySummaryRow`)
- **test** `ActivitySummaryTests`: RPC params (raw search, uncategorised wins over a category, nulls), decoding (string money, null dates, malformed money), header wording, display states, model loading and failure isolation

## FAB cards on one account — 2026-10-09

### Backend (Supabase)

- **fix** `20261010001400_merge_accounts_and_fab_cards`: production's FAB relationship was split over two accounts, because statements from 2025-09 name the supplementary card and ingest made a new account for a card number it had not seen. The 2777 account (14 statements, 722 lines and transactions) is merged into the 6290/2132 account and 6290 is `replaced`. The migration set 2132 primary and 2777 supplementary from the owner's first account; FAB's statements say the opposite (`Main Card : … 2777`, `Supplementary Card : … 2132`), so production's flags were then set to the bank's labels by hand: 2777 main (it replaced 6290), 2132 supplementary. Guarded by the exact card codes, accounts and flags, so it is a no-op anywhere else and on a re-run. New `private.merge_accounts(profile, from, into)` moves cards, statements, statement lines, transactions, SMS and match reviews and closes the emptied account. pgTAP `28_merge_accounts`

## SIB "Statement details" export — 2026-10-09

### Parser

- **fix** The SIB app's "Statement details" PDF (card summary, then the rows since the last billing date) failed with `BANK_UNDETECTED`: none of the detection markers matched. It is now detected (`Statement details` + `Card issuer SIB`) and parsed by the transaction-history parser, whose row layout it shares; the card number comes from the bare `Card 5290 xxxx xxxx 4821` header and the card type from `Card issuer …`. A replaced card's opening "Balance Migration" row is an `adjustment`, not a purchase, so the old card's billed balance is not counted as spend twice. 2026.10.5
- **test** `test_sib_statement_details_export_is_a_history`, `test_sib_app_statement_details_export_is_detected`

## SMS: the phone sends, the server decides — 2026-10-09

### iOS

- **fix** "Log Bank SMS" dropped messages on the phone with a regex guess ("Skipped: not a credit-card transaction"), so three ENBD alerts on 2026-10-09 never reached Bank Ledger and production had no SMS at all. The phone now drops only one-time passcodes and empty input; every other message is sent and `process_sms` classifies it (debit-card/account alerts are stored `ignored`, unknown formats `unparsed` with the LLM fallback) (`SMSCapture`)
- **feat** Settings → SMS → **Recent captures**: the last 20 runs with outcome, sender and message length (never the text), so a Shortcut passing the wrong field is visible (`CaptureLog.recent`)
- **change** "Send test" uses a synthetic one-time passcode, the one kind of message still dropped on the phone; the SMS-shape patterns the old filter used now live in the Sentry scrubber, which still needs them (`SensitiveText`), and also catch `₹` and `Rs.` amounts
- **test** `SMSCaptureTests` (debit, account, no-amount and the ENBD "Payment of AED … with Credit Card" shapes are sent), `OutboxTests` (recent-capture history, debit alert delivered as `ignored`)

### Web

- **docs** Settings → iPhone SMS guide: privacy note and banner meanings match the new behaviour

### Docs

- **docs** CLAUDE.md §5.5, `apps/ios/CLAUDE.md`, `apps/ios/README.md`, ARCHITECTURE.md SMS path
- **ci** No macOS jobs on GitHub: `ios-build.yml` is deleted and `ci.yml`'s `ios` job removed (together ~30 billed minutes on every iOS PR and again on the `main` push). The pre-push hook does that work on the Mac: `swift test` as before, and now the unsigned app + share extension compile when app code changes (a push to `main` archives and signs instead). Without Xcode these checks fail rather than skip (docs/ci-cd.md)

## Glued cities backfilled — 2026-10-09

### Backend (Supabase)

- **fix** `20261010001300_glued_place_backfill`: descriptions ingested before parser 2026.10.4 get the same space between merchant and city (`CAREEM HALA RIDEDUBAI` → `CAREEM HALA RIDE DUBAI`; production: 1,374 current statement lines). Only `statement_lines.description` changes (`description_raw`, `raw` and `line_key` stay as printed); transactions are refreshed from their evidence, keep their codes and merchants, and recategorise. Rule patterns written against the glued text (`KITOPIDUBAI`, `OSNDUBAI`, `CAREEMDUBAI` …: 11 seed rules per profile) get the space too, in `private.seed_rules` and in non-regex `category_rules`, so they match old and new statements alike. `private.backfill_glued_places()` is idempotent; `private.separate_glued_place()` is the SQL twin of the parser's helper. pgTAP `27_glued_place_backfill`; a parser test keeps the two place lists equal.

## Parser separates glued cities — 2026-10-09

### Parser

- **fix** MASHREQ statements (1,144 of 1,233 production lines) and SIB history (193 of 227) print the city glued to the merchant (`careem hala ridedubai`; the PDF text run itself has no gap). `merchant_normalized`, which becomes the transaction description, now separates it (`CAREEM HALA RIDE DUBAI`) for any bank, using the place list of `public.merchant_key` (`ccs_parser/places.py`). `description_raw` and `legacy_fingerprint` are unchanged, so line identity (`line_key`) and re-parses are unaffected; lines already ingested keep their text. `PARSER_VERSION` 2026.10.4; MASHREQ golden snapshots updated.

## One merchant per merchant — 2026-10-09

### Backend (Supabase)

- **fix** `public.merchant_key()` v2 (`20261010001200_merchant_key_v2`) strips the noise that split one merchant into many: a city glued to the name by statement column concatenation (`CAREEM RIDEDUBAI`, `ADNOC MAYSALOON 783SHARJAH`), reference tokens anywhere after the first word (`SPOTIFY AB P33F7BD2DC …`, `WIX COM 1198729259 …`), more country/state codes, foreign amounts (`… MYR 5 70 0`) and the website column (`WWW WIX COM`). On production's descriptions: 802 keys → 691, keys holding a reference 91 → 3. Branch and store names stay distinct (`MCDONALDS OASIS MALL`, `ADNOC AL SAFA 2`).
- **feat** `private.rekey_merchants()` (service role / owner; re-runnable after any key change) merges merchants that now share a key onto a survivor that keeps its `merchant_code` (the key's holder, else an alias target, else the one with most transactions), records every old key in `merchant_aliases`, carries each profile's merchant category (manual beats llm), category skip and recurring series to the survivor, and repoints transactions through `refresh_transaction` so categories recompute. Merged-away rows that conflict stay inert; nothing is deleted. The migration runs it once. pgTAP `26_merchant_key_v2`.

## Category taxonomy v2 — 2026-10-09

### Backend (Supabase)

- **feat** Ten new categories for every profile, so spend no longer piles into two or three (prod: Shopping 27% + Dining 18%; Transport 26% + Dining 17%): Food Delivery, Online Marketplaces, Fashion, Beauty & Personal Care, BNPL Instalments, Car & Fuel, Flights, Telecom & Internet, Bank Fees & Interest (`fee`), Education. Existing categories keep their codes and names (`20261010001100_category_taxonomy_v2.sql`)
- **fix** Seed rules moved into them, and the over-broad ones fixed: `UBER` (Travel) caught rides and Uber Eats; `EMIRATES` (Travel) caught Emirates Hospital, Emirates Leisure Retail and Emirates Fast Food and is now an airline-only regex; cash-advance, membership and annual fees, finance/interest charges and Murabaha profit debits are Bank Fees & Interest; salons and spas are Beauty & Personal Care; Lime is Transport. 46 new seed rules (244 per profile). Guarded content migration: only rules still exactly as seeded are re-pointed
- **test** `tests/25_category_taxonomy_v2.test.sql` (40 rule cases); the existing-profile path was replayed against production descriptions (3,136 transactions) before release

## LLM categorisation: fewer re-asks, bigger batches — 2026-10-09

### Backend (Supabase)

- **perf** `llm_categorize` batches 100 merchants per call (was 25), and the prompt and structured output use short refs (`m1…`, `c1…`) instead of 30-character codes, which were most of the output tokens (`_shared/llm.ts`, `LLM_BATCH_MAX`)
- **fix** A category change no longer re-asks every LLM-categorised merchant: a suggestion is re-asked only when its category was archived or edited after it, or its confidence is below 0.8; declined merchants are still re-asked (`private.enqueue_llm_categorize`)
- **fix** `worker_llm_context` sends up to 3 distinct example descriptions (it often sent one description three times)
- **test** `tests/24_llm_categorize_tuning.test.sql`; ref mapping and batch cap in `llm_test.ts` / `llm_jobs_test.ts`

## Bank logos visible in production — 2026-10-09

### Web

- **fix** The production CSP (`apps/web/vercel.json`) allowed images only from the site itself, so every bank logo from the `bank-logos` Storage bucket was blocked and the code fallback showed. `img-src` now allows `https://nkmylznisjcnmqbxosey.supabase.co`, and `scripts/ci/web-smoke.sh` asserts it

## Web smoke runs once per push — 2026-10-09

### Docs

- **ci** `web-smoke.yml` runs on pushes to `main` that touch the web app, waits for Vercel's Production deployment of that commit, then smoke-tests; it no longer triggers on every `deployment_status` (dozens of skipped runs per release). Daily and manual runs unchanged (docs/ci-cd.md)

## SIB push login — 2026-10-08

### Scraper

- **fix** SIB's portal now confirms logins with a push to the SIB app (Face ID / Touch ID) instead of a password step. The adapter detects the prompt and waits for approval (`SIB_BIOMETRIC_WAIT_S`, default 180 s, a log line per 3 s poll), then continues; the password path still works (`tests/test_sib_biometric.py`)

## Gmail alerts muted — 2026-10-08

### Backend (Supabase)

- **chore** Gmail isn't configured yet, so nothing from `gmail-push` / `gmail-watch-renew` (or tagged as Gmail) reaches Sentry, and ops-monitor skips Gmail mailbox and watch issues, until `GMAIL_SENTRY_ALERTS=on` (`_shared/sentry.ts` `isGmailEvent`, `ops-monitor/health.ts`; tests in `ops_monitor_test.ts`, `sentry_scrub_test.ts`)

## iOS: statement detail, upload log, spend split, bank logos — 2026-10-10 (branch `ledger-v2`)

### iOS

- **feat** Statement detail: tapping a cycle on Statements pushes a screen with the bank logo, cards, period, statement and due dates; tiles for opening balance, total debits, total credits, closing balance, minimum due and credit limit ("—" when the PDF didn't print one); reconciliation with its status chip and every check as a sentence with the server's figures ("Debit lines add up to AED 5,120.10, but the statement says …"); then **Debits** and **Credits** with count and total, each line with date, merchant (the printed text under it when it says more), category dot, AED amount and the FX original. A matched line opens the transaction sheet (`transactions(codes:)`); a held line says "Not matched yet". Loading / failed (P0002 explained) / empty states, VoiceOver sentences per line, a one-column grid at accessibility sizes. `rpc('statement_detail')` → `StatementDetail`, `StatementDetailModel`, `ReconPresentation`
- **feat** Upload log (IOS-17): the explainer card is gone; a toolbar `+` picks PDFs and uploads them one request each (one bad file no longer rejects the batch) into a live per-file log fed by `document_events` (Realtime INSERTs on the profile, a fetch after each upload, and a 4 s poll while anything is moving): stage icon, time, the server's message, and for a failure what to do (`UploadAdvice`: a wrong PDF password → "Set the password on the web: Settings → Statement passwords"). "N of M done · K failed", per-file steps, Clear. Each row of Uploads opens that document's processing log (live), and a failed upload shows its `parse_error` and advice in the list. The second "Statements" heading is now "Cycles". `UploadSession`, `DocumentLogModel`, `DocumentEvent`, `StagePresentation`; `UploadResponse` items carry `parse_status` and `requeued`
- **fix** IOS-16r: a PDF the share extension saved that the server refuses for good (too large, not a PDF, no longer an owner) moves to `pending-uploads/rejected/` with its reason instead of blocking every later PDF; transient failures still stop the run. Statements shows "N PDFs waiting to upload" with Send now (to the "SMS go to" ledger, where the extension filed them) and each refused PDF with its reason and Remove
- **feat** Share extension stays light: after sending it says "Sent: watch progress in Bank Ledger → Statements"
- **feat** Insights → Monthly spend: a None / Category / Bank / Merchant control over `rpc('spend_breakdown')` (top 10 + Others): stacked Swift Charts bars in token colours (a category's `color_token`; banks and merchants take the chart palette by rank; Others its own neutral), a legend, tap a month to pin a callout with each group's AED and share of that month, and each group's total and share for the range (bank logos in the bank split). Group keys are decoded without key conversion so codes reach the screen unchanged. `SpendBreakdown`, `SpendSplitModel`
- **feat** Bank logos replace bank codes on Overview's cards, Statements (cycles, uploads, detail), Activity rows and the transaction sheet, the bank split, Review subjects (`ReviewItem.bankCode` / `subjectBody`) and parked SMS in Settings (sender → bank via `banks.sms_senders`). `BankLogo(bankCode:size:)` reads `BankCatalog` (the `banks` table once per ledger, the seed names offline): the six bundled marks (`Assets.xcassets/Bank/<CODE>` from `assets/banks/`), else `{supabase}/storage/v1/object/public/bank-logos/{logo_path}`, else a monogram; ENBD, SIB, EIB and FAB sit on a light chip in dark mode; VoiceOver reads the bank's name
- **fix** IOS-20r (chart part): the monthly bars, the stacked split and Overview's category ring carry `accessibilityChartDescriptor`s (audio graph and data table) with a spoken summary, built from LedgerKit's `ChartAccessibility`
- **test** `StatementDetailTests`, `SpendSplitTests`, `UploadLogTests`, `BankDirectoryTests` with fixtures in the backend's exact shapes (`statement_detail`, `spend_breakdown` category / bank / empty, `document_events`, `banks`); the stub API gains the new reads, scripted uploads and a Realtime feed. Verified end to end in the simulator against an isolated local stack with the backend RPCs (three PDFs: imported, imported, wrong password with its advice; statement detail and its transaction sheet; category and bank splits with the callout; dark-mode chips)

## Web: statement page, bank logos, upload log, spend split, infinite scroll — 2026-10-10 (branch `ledger-v2`)

### Web

- **feat** Statement page `/statements/$stmtCode` (`statement_detail`): bank logo, cards, period, statement and due dates; tiles for opening balance, total debits and credits, closing balance, minimum due (with "in N d"), utilisation and the reconciliation chip; **Debits** and **Credits** sections with count, total and every line (date, merchant or printed description, category dot, AED with the FX original); a line opens the transaction drawer (`?txn=`); reconciliation checks explained; *Open PDF*, *In Activity*; a collapsible processing log. Every statement row (Cards & statements, the Overview card's statement balance, a statement line in the drawer's evidence) links to it; P0002 shows "not in this ledger"
- **feat** `BankLogo` (`components/bank-logo.tsx`): each bank's mark from the public `bank-logos` bucket (`banks.logo_path`), accessible name = bank name, the short code when there is no logo or it fails to load; on a light chip (`.bank-chip`) so the navy/purple marks stay legible in dark mode. Shown on Overview cards and pending SMS, Cards & statements (cards, statements, documents), Activity rows, filters (account and card options) and drawer, calendar day sheet, Review candidates and templates, Settings email routes, and the bank split
- **feat** Live upload log: after an upload each file lists its `document_events` as they arrive over Realtime (initial fetch + inserts, de-duplicated, in timeline order): received, saved, queued, reading, read, imported, or duplicate / failed / retrying, with stage icons and times. Failures are highlighted; a wrong or missing PDF password links to *Settings → Statement passwords* (`#statement-passwords`), transient failures offer *Read again*. The same log is in the statement page and behind *Processing log* on each Documents row
- **feat** Monthly spend split (`spend_breakdown`, top 10 + Others): on Insights → Trends (month buckets; new *Bank* grouping, which is monthly only) and a new *Monthly spend* card on Overview (six months to the selected month). Stacked bars in token colours (a category's own `color_token`; banks and merchants by palette rank; Others neutral), tooltips with AED and share of the month, and a totals table (raw total and the server's share for the range; category rows link to Activity). No client-side totals
- **feat** Pagination: below 768 px Activity, Statements, Documents and Review scroll forever (IntersectionObserver sentinel, 100 per page, rows de-duplicated across pages, spinner, retry row, end of list, a filter change starts from the top, *Load more* fallback). Wider screens keep numbered pages with 100/200/500/1000/2000; `page` and `size` are in the URL for Statements, Documents and Review too (`/cards?tab=…&page=&size=`, `/review?page=`), and a filter or tab change returns to page 1
- **fix** WEB-48: uploads send at most 20 files (the Edge Function's limit), say "Up to 20 files", reset the file input and ignore drops while an upload is in flight
- **chore** Statements and Documents tabs moved out of `routes/cards.tsx` into `components/cards/`; `usePageState` removed (every paged list keeps its page in the URL); `useTransactions`, `useStatementCycles`, `useDocuments`, `useOpenReviews` and `useSpendSeries` take an optional `enabled`
- **test** `banks`, `statements`, `document-events`, `lib/infinite`, `spend-split`, `transactions-paging`, upload file cap

## Bank logos — 2026-10-08 (branch `ledger-v2`)

### Web

- **feat** `assets/banks/<BANK_CODE>.png` for ADCB, EIB, ENBD, FAB, MASHREQ and SIB: 256×256 transparent PNGs (1–4 KB each) of each bank's mark, built from the banks' own site SVGs or Wikimedia vector files, legible at 24–32 px. `scripts/brand/upload-bank-logos.sh [--dry-run]` upserts them into the public `bank-logos` Storage bucket (`SUPABASE_URL` + `SUPABASE_SECRET_KEY`; the key goes on `apikey` via curl's stdin config, never argv or output)

### Docs

- `assets/banks/README.md`: per-bank source URLs, retrieval date, trademark note, and the dark-mode advice (navy/purple marks go on a light chip)

## Mobile web audit — 2026-10-09 (branch `ledger-v2`)

### Web

- **fix** Drawers and sheets cut off at the left edge on iPhone ("yment Received Thank You", "ED 2,201.00"): iOS Safari zooms the page in when a text field under 16px gets focus and never zooms back out, and the transaction drawer's category picker auto-focused a 13px search box. Every text field is now 16px on phones and touch screens (one unlayered rule in `styles.css` that beats `text-sm` utilities), and the picker no longer auto-focuses its search box on touch screens (the keyboard covered the list)
- **fix** `Sheet` / `Dialog` (`components/ui/dialog.tsx`): long titles and descriptions wrap (`overflow-wrap: anywhere`) instead of pushing the close button out; the close button is a 40px box with a 44px hit area; the body clips sideways so wide content scrolls inside the sheet; the bottom sheet and its footer clear the home indicator (`env(safe-area-inset-bottom)`); `Dialog` is sized with `%` of the viewport box instead of `100vw`; both accept `onCloseAutoFocus`
- **fix** Safe areas: the phone header clears the status bar / notch (`viewport-fit=cover`), page content clears the landscape notch and the home indicator, and toasts sit above the tab bar *and* the home indicator. Toasts no longer cover the tab bar on tablets (768–1023px, where the tab bar still shows) and span the width on phones
- **fix** `body { overflow-x: clip }` so a stray wide element can never make a page pan sideways on a phone; `-webkit-text-size-adjust: 100%` stops iOS inflating text in landscape
- **fix** Tap targets on phones: menu items, select options and category-picker rows are 40px below `lg` (32px on desktop); the select's small trigger, segmented controls, toast dismiss, brand link and the privacy page's back link get the 44px `tap` hit area. Popovers, menus and selects are capped to the available width (`--radix-*-content-available-width`)
- **feat** WEB-44: tab strips (Insights' nine tabs, Rules, Settings) fade at the edge where more tabs are hidden and scroll the active tab into view (`useScrollEdges`, pure `scrollEdges` / `revealScrollLeft` in `lib/scroll.ts`)
- **fix** WEB-30: italic "Uncategorised" no longer loses its last glyph when truncated
- **fix** WEB-32: the Statements row's status column has a fixed width, so the "Doesn't add up" badge no longer shifts the other columns
- **fix** WEB-33: Rules and Settings use the same page container as the other screens
- **fix** Review: a "Possible matches" row no longer squeezes the merchant to "Dun…" with the date stacked one word per line on a phone; the amount and "Same purchase" wrap below instead
- **fix** Rule editor on phones: "When the description" wrapping to two lines no longer pushes the match-type select below the text field
- **fix** More phone hit areas: Overview category rows (40px), "All activity", Insights merchant names, Documents file names, the search box's clear button, the ledger switcher and the privacy-policy links
- **feat** WEB-24 (mobile part): Activity has a **Select** button on phones that shows the checkbox column; in select mode tapping a row toggles it, and the bulk bar offers **All** and a **Categorise…** picker (it used to show a state-like "Uncategorised" pill). The bulk bar sits above the tab bar and the home indicator. Exclude, CSV export and a server-computed total remain open
- **fix** WEB-20: each Activity row's main action is a real `<button>` inside a `role="cell"` span, not `<button role="cell">`
- **fix** WEB-19: closing the URL-driven transaction drawer returns focus to the row that opened it
- **fix** WEB-43: closing a drawer opened from the list pops its history entry (Back no longer reopens it); a deep-linked drawer closes with `replace`, and a "Reverses / Reversed by" link swaps the drawer in place
- **fix** Transaction drawer on phones: narrower label column, a 32px amount, long raw statement lines wrap anywhere
- **feat** WEB-15 / WEB-22r: the calendar heatmap stops at today (future days are neither drawn nor counted: "134 days of 161", not "of 184") and sizes its cells to the card (`fitCalendar`); on a phone a long range turns into 7 day columns with a row per week (~34px cells instead of 13px), and tapping a day opens a sheet with that day's transactions and an "Open this day in Activity" link
- **test** `lib/scroll.test.ts` (`scrollEdges`, `revealScrollLeft`), `components/charts/heat-fit.test.ts` (`fitCalendar`, `calendarEnd`)

## iOS: previous months and infinite scroll — 2026-10-08 (branch `ledger-v2`)

### iOS

- **feat** Month switcher on Overview and Insights (`‹ October 2026 ▾ ›`): chevrons step a month back or forward, the title opens a month picker grouped by year with a "This month" shortcut, and swiping the switcher sideways changes month. You can't go past the current Dubai month or before the ledger's first transaction (`filter_meta.date_range.min`, or 24 months while that is unknown). The two tabs share one `LedgerKit.MonthSelection`. The current month is sent as `p_month = null` and follows the calendar at Dubai midnight on the 1st. VoiceOver: chevrons read "Previous month, September 2026", the title is adjustable (swipe up/down), and every target is 44 pt. Logic lives in `MonthRange` / `MonthSelection` / `LedgerDates.monthScopeLabel` / `monthPhrase`
- **feat** Overview for a past month: `overview(p_month)` drives the hero, category ring ("Where it went · September 2026") and "N uncategorised in September". The pending strip and "Latest" are about now, so they show only on the current month. A completed month's reference line is the whole previous month ("August AED 9,112", the server's `spend_prev_month`), not "Same day last month". Insights' 3M/6M/12M period now ends with the selected month (captioned "Last 6 months to March 2026"), and budgets use `budget_status(p_month)`
- **feat** Infinite scroll (`LedgerKit.Paginator`, 100 rows per page) on Activity, statement cycles, uploads and Review. The next page loads as the reader nears the end, with a spinner row, an end-of-list row ("All 1,234 transactions"), and an error row with Try again that doesn't retry by itself. Only one page is in flight at a time, and a page fetched for an older query or ledger is dropped, never appended. Rows already shown are not added twice. Pull-to-refresh starts again from page 1. Realtime and foreground refreshes use `refreshHead`, which updates the first page and keeps the scrolled pages. `LedgerAPI.transactions` / `documents` / `reviewInbox` take a `PageRequest` and return exact counts. `statement_cycles` takes only a limit, so its pages are slices of a growing limit
- **fix** IOS-15: the Activity filter sheet edits a copy: Apply changes the list, while Cancel or a swipe-down changes nothing. Activity now has a month filter. Paging ignores pages from a superseded query, and recategorising re-reads the affected rows (the merchant's loaded rows when "apply to every" is on) and patches them in place, so it no longer resets to page 1. A row that leaves an "Uncategorised only" or category filter is removed and the next page's offset follows
- **fix** IOS-14: switching ledger resets every tab (`LedgerScreens.select`) before anything loads, and the tabs render only when they point at the selected ledger, so the previous ledger's numbers never flash. Overview and Insights drop responses superseded by a newer month or ledger (`RequestGate`)
- **fix** IOS-13: Realtime resubscribes with exponential backoff (1 s … 60 s; resets after 30 s healthy) while the ledger stays selected. A failed channel is removed so the retry builds a fresh one, and each reconnect refreshes every opened tab. The foreground refreshes every opened tab, Insights included, and leaves unopened tabs alone
- **test** `PaginatorTests` (paging to the end, single in-flight page, stale page dropped, retry row, offset shift dedupe, `refreshHead`, patch/remove offsets, reset), `MonthTests` (range, labels, Dubai rollover, Insights range, switcher bounds and VoiceOver strings), `ScreensTests` (Activity paging / filter copy / in-place recategorise, ledger switch, refresh fan-out, Realtime resubscribe)

## Statement detail, spend breakdown, bank logos, document timeline, replacement cards, merchant masking — 2026-10-10 (branch `ledger-v2`)

### Backend (Supabase)

- **feat** `public.statement_detail(p_profile_code, p_stmt_code)` (member read): one statement with its current debit and credit lines, each line with its transaction, merchant name and category; money as decimal strings (shape: ARCHITECTURE §6). Migration `20261010000200`
- **feat** `public.spend_breakdown(p_profile_code, p_from, p_to, p_group_by, p_top_n = 10)` (member read), built only on `v_spend`: monthly spend by `category` / `bank` / `merchant`, top N groups plus `__other__` ("Others"), every month zero-filled, 4-dp shares (ARCHITECTURE §6). Migration `20261010000200`
- **feat** Bank logos: `banks.logo_path` (seeded `<bank_code>.png` for the six banks, guarded), public Storage bucket `bank-logos` (no client writes); `statement_cycles` gains a `logo_path` column, `overview` accounts and `filter_meta` banks carry `logo_path`. Migration `20261010000100`
- **test** pgTAP `20_statement_rpcs_and_logos.test.sql` (contract keys, ordering, decimal strings, top-N fold, zero-filled months, non-member refusal, logo_path in the existing RPCs)
- **feat** Statement upload / parse timeline: `public.document_events` (`dev_…`, `doc_code`, `stage`, `level`, `message`, `detail`), member read, in the `supabase_realtime` publication. Written by `storeDocument` (`received`, `stored`, `queued`, `duplicate`) through the service-role RPC `log_document_event`, `begin_document_parse` (`parsing`), the worker (`parsed`: bank, statements, lines, parser warnings), `ingest_parsed_document` (`ingested`: statements, lines new/unchanged/withdrawn, transactions created/matched, lines held, cards added), `fail_document` (`failed` with a sentence per error code, e.g. a wrong PDF password; `retry` when transient), `resubmit_document` and `requeue_documents` (`retry`). Messages carry no passwords, PDF text, line text or SMS bodies. Migration `20261010000400`
- **feat** `ledger-nightly` purges `document_events` older than 90 days (`private.purge_document_events`). Migration `20261010000410` (flagged destructive by the deploy gate: PRODUCTION §2.3)
- **feat** Edge: `_shared/documents.ts` `logDocumentEvent` (never throws), `uploadEvents`, `formatBytes`; `worker/parse_document.ts` `parsedEvent`. statements-upload already returned `doc_code` per file; documented with the timeline
- **test** pgTAP `22_document_events.test.sql` (full timeline order, messages and counts, friendly failure text without the raw error, retries, member-only reads, no client writes, cross-profile refusal, 90-day purge); `11_privileges` matrix (`document_events:authenticated:SELECT`); deno `_tests/document_events_test.ts`. Run locally: an upload through `statements-upload` (service token) and its duplicate produced `received → stored → queued` and `received → duplicate`, read back by the member through PostgREST

- **feat** Replacement cards: a SIB history extract for an unknown card joins the bank's only active account (card type matches, first transaction not more than 31 days before the account's last line), the older cards become `replaced` and SMS held for the new number are re-processed; other banks and real statements still create a new account for an unknown card. Owner RPC `add_replacement_card(p_profile_code, p_card_code, p_new_last4)` registers a re-issued number on the old card's account. `ingest_parsed_document` passes the statement kind and first transaction date to the new 11-argument `resolve_statement_account` (the 9-argument form remains and never merges). Migration `20261010000500`
- **test** pgTAP `23_replacement_cards.test.sql` (second card on the same account, old transactions on 6774-style old card, waiting SMS re-processed, new SMS matched, another product stays separate, owner RPC, refusals); `08_tenant_isolation` (statement_detail, spend_breakdown, document_events, add_replacement_card across profiles)

- **feat** Private merchant masking (keyword-free; configured only in the database): `private.merchant_masks` (validated regex, generic name, optional category) and `private.masked_originals`, unreadable by every client role and the service role, with no RPC, view or policy. BEFORE triggers mask statement lines, SMS (body, merchant fields), transactions and new merchant rows at the source; `private.apply_merchant_masks(p_profile_code)` (also fired by a statement trigger on the masks table) re-masks existing lines, SMS, transactions, global merchants/aliases and insights. `line_key` and `body_hash` are untouched, so re-parses stay idempotent and never unmask. The mask's category is a merchant-level manual choice on the generic merchant (outranks rules and LLM; a transaction's manual category wins), also set for a profile whose first masked transaction arrives later. Migration `20261010000600`
- **test** pgTAP `21_merchant_masks.test.sql` (fake token only): existing rows, new statement lines, parsed and unparsed SMS, re-parse without duplicates or unmasking, activity and merchant search, `spend_breakdown` / `statement_detail`, category precedence, a second profile, validation, and that anon / authenticated / service_role cannot read the private tables

### Parser

- **fix** SIB card numbers (the SIB card ending 6774 was replaced by a new number): history exports read the card from `Account no.` / `Card no.` / `Card number` headers through a masked-number pattern (any of `x`, `X`, `*`, `•`, with or without the BIN), each row belongs to the card of the header above it, and each billing cycle's `primary_card_last4` is its majority card. E-statements also accept a lower-case mask. Existing outputs are unchanged
- **chore** `PARSER_VERSION` / `pyproject.toml` 2026.10.3 (new synthetic case)
- **test** `test_sib_parser.py` (replacement-card history, two card sections in one export, lower-case masked statement card, mask variants); synthetic golden `sib_history_new_card` (card 3333 on every line and cycle)

### Scraper

- **fix** SIB: after a card is replaced the portal lists the old card next to the new one, and the adapter clicked the best "credit card" match, i.e. the first (retired) card, so new transactions never arrived (SIB data stopped on 2026-08-10). The adapter now reads the masked card numbers in the Credit Card section (shadow roots included) and exports each card in turn (`SIB_CARD_LAST4S` / `card_last4s` picks them), choosing the card by its masked number in the section and again in the E-statement popup (native `<select>` or the most specific element). No card choice on the page keeps the single-card flow. Every new wait has its `SIB: waiting …` log line; download diagnostics carry `cards` and each entry's `card_last4`
- **test** `test_sib_cards.py`: masked-number reading, config parsing, one export per card with tagged diagnostics, the single-card fallback, and an AST guard that every SIB `wait_for_timeout` ≥ 700 ms, `expect_download` and `sleep` is preceded by a `logger.info("SIB: waiting …")` (CLAUDE.md §7)

### Docs

- ARCHITECTURE §3 (`banks.logo_path`, `bank-logos` bucket, `document_events`, cards), §4 (document timeline, replacement cards), §5 (private merchant masks), §6 (`statement_detail`, `spend_breakdown` shapes), §7 (Realtime); README Edge, RPC and scraper env tables; PRODUCTION §2.3 (destructive flag), §2.6 (nightly purge), §11 (uploading the logos, merchant masks, the replaced SIB card)

## Edge Functions and CI backlog (audit P2/P3) — 2026-10-09 (branch `ledger-v2`)

### Backend (Supabase)

- **fix** SRV-18 Sentry hygiene: `scrubString` replaces free-text email addresses with `[email]`; `pgErrorToHttp` returns fixed messages for 23505/23503/23514 (no constraint or key names to clients; RPC-raised 22023/42501/P0002 messages are kept). Request isolation was **verified broken**: the Deno SDK has no async context, so a scope tag set in one request leaked into another request's events. Per-request tags (`function`, `execution_id`, new `setRequestTag`) now live in an `AsyncLocalStorage` applied by an event processor; nothing request-specific is written to Sentry's shared scopes. Test: `_tests/sentry_scope_test.ts` interleaves two `withSentry` handlers against a fake ingest server (failed before the fix)

- **fix** SRV-05 `gmail-push`: a time budget (`GMAIL_PUSH_BUDGET_MS`, default 100 s; 503 so Pub/Sub redelivers and continues), the cursor advances after every fully processed history page, `history.list` is filtered to the watch label (when the watch has one), and a 404 cursor reset is a Sentry error followed by a bounded `messages.list` backfill (`has:attachment` since a day before the last sync, ≤5 pages) instead of silently skipping mail. Per-mailbox logic moved to `gmail-push/process.ts`
- **fix** SRV-19: permanent `gmail-push` failures (malformed envelope, `invalid_grant`, a mailbox without a token, missing OAuth config, Gmail 400/401) are recorded and acked (200); transient ones still return 500. The subscription's dead-letter topic (10 attempts) already exists (PRODUCTION §5)
- **fix** SRV-14: a failed save of a rotated Microsoft refresh token is reported (warning); `gmail-push`, `gmail-watch-renew` and `outlook-poll` record `sync_state.last_error` as an opaque code (`TOKEN_REFRESH_FAILED:invalid_grant`, `GMAIL_503`, `GRAPH_410`, …) and clear it on success
- **fix** SRV-15: `saveSyncState` calls the database pass's `save_mailbox_sync_state` (a jsonb merge under a row lock; the Gmail cursor and both timestamps never move back). A non-numeric `gmail_history_id` is dropped from the patch so it can't clear the stored cursor; there is no fallback write. (This branch's own `merge_mailbox_sync_state` migration was dropped in favour of it before reaching production.)
- **perf** SRV-07: attachment base64 is decoded with `Uint8Array.fromBase64` (or `@std/encoding` 1.0.11 on older runtimes): ~45 ms instead of ~1.4 s for 20 MB. Attachments whose provider-reported size is over 25 MB are recorded as ignored (`FILE_TOO_LARGE`) without downloading
- **fix** SRV-20: re-sending a PDF whose parse **failed** calls `resubmit_document`, which queues it again; upload results now carry `parse_status` (and `requeued: true`). The worker claims a document with `begin_document_parse` (it replaces `worker_document_context` and the worker's own `parsing` update): a message for a document already `parsed` or `failed` is a duplicate or stale delivery and is deleted without touching the document (`ALREADY_PARSED` / `ALREADY_FAILED`); a real re-parse (`requeue_documents`, `resubmit_document`, `requeue_dlq`) resets the status to `queued` first
- **refactor** SRV-23: `_shared/provider.ts` (ProviderHttpError, one base64 decoder, size check); `prepareDocument` validates once and `storeDocument` takes only prepared documents; `processParseMessage` split into fetch (`callParser`), classify and apply; `fail_document` and the `parsing` status write are checked (a failed write leaves the message for its visibility timeout)
- **feat** SRV-10 / SRV-22 / DB-25 `ops-monitor`: `evaluateHealth` matches `ops_health()` from `20261009000400` exactly. New issues: `mailbox_errors` (error; mailbox code, provider and `last_error.code`), `mailboxes_stale` and `gmail_watch_expiring` (warning; mailbox codes), `job_errors` when `job_errors_24h > 0` (error), and `documents_queued_age` when `documents_queued_oldest_age_s` passes `OPS_QUEUED_DOCUMENT_AGE_S` (3 h). A DLQ is an error only when it grew since the last check (`newest_age_s < 900`), then a daily warning reminder, instead of an error every 15 minutes. `documents_stuck` (now `parsing` > 1 h), `recon_failed` and `review_backlog` (7-day windows; `open_reviews_total` in the extra) keep their issue names
- **feat** NEW-1: new Edge Function `member-invite` (user JWT, owner only; `verify_jwt = false`). `{profile_code, email, role?, action: "invite"}` runs `add_profile_member` as the caller and, when it returns `invited`, sends the Auth invite (`auth.admin.inviteUserByEmail`) with the service client; `action: "resend"` re-sends to a pending member. A pending invite only attaches once the address is confirmed (DB-23), so an invited person stays pending with an unconfirmed Auth user: no invite goes to an address invited in the last 10 min (Auth's `invited_at`, looked up with `auth.admin.listUsers`), and a confirmed account is `ALREADY_ACTIVE`. Also 10 sends per caller per hour per isolate and Auth's own email limit; a failed or held-back email still leaves the member pending (`invite_sent: false, invite_error`). The invite link redirects only to the request's own Origin (and `ALLOWED_ORIGINS` when set); Auth's redirect allow-list still applies. Web Settings → Members and iOS buttons are a follow-up (NEW-1r)
- **test** `member_invite_test.ts` (validation, same-origin redirects, owner/viewer, limits, cooldown, paged user lookup); `e2e_local_test.ts` now covers a **viewer** getting 403 on `statements-upload` and `sms-ingest`, `member-invite` end to end (viewer 403, owner invite creates an unconfirmed Auth user and leaves the member pending, resend and re-invite held by the cooldown, foreign redirect 422), the failed-duplicate resubmit, and `delete_profile` followed by a worker run that removes the profile's PDFs
- **test** SRV-11: `_tests/fake_db.ts` (in-memory supabase-js stand-in and fake fetch); `gmail_push_test.ts` (cursor init, per-page cursor, deadline, 404 reset + backfill, bounded backfill, size skip, revoked grant), `outlook_poll_test.ts` (resume from `nextLink`, 410 restart, deadline, token rotation persisted / save failure tolerated), `ingest_paths_test.ts` (`storeDocument` order, 23505 race, orphan removal, failed-duplicate resubmit, `saveSyncState` merge, worker staleness through `begin_document_parse`, checked status writes), `ops_monitor_test.ts` (the exact `ops_health()` shapes), `llm_jobs_test.ts`, `storage_cleanup_test.ts`
- **feat** DB-21e: the worker drains `storage_cleanup` (the PDF paths `delete_profile` queues): it removes them with the service client's Storage API, only in the `statements` bucket and only paths shaped `<profile_code>/<file>` (anything else is skipped and reported), retries a Storage error by visibility timeout and dead-letters after 5 reads. Migration `20261009100100_storage_cleanup_worker.sql`: `storage_cleanup_dlq`, `kick_worker` also wakes the worker for `storage_cleanup`, and `drain_dlq` / `requeue_dlq` accept it. pgTAP `19_storage_cleanup_worker.test.sql`
- **feat** DB-37: `llm_categorize` passes the batch's merchant codes to `apply_llm_suggestions(p_merchant_codes)`, so merchants the model declined are recorded and not re-enqueued every night. `sms_fallback`: a 22023 from `propose_sms_template` (including a sender that isn't one of the bank's) is dead-lettered once, never retried

- **chore** SRV-13 (Edge part): `supabase/functions/deno.lock` is committed and frozen (`deno.json` `lock.frozen`); the edge runtime bundles with it (verified locally: a corrupt lock fails to boot). CI, the pre-push hook and the deploy job's test step run `deno check --frozen` / `deno test --frozen`, so a stale lock never ships
- **chore** X-16r: committed `supabase/functions/.env.example` (names only, grouped required / production-only / local-only / optional); `.gitignore` re-allows `.env.example` after its trailing `.env*` rule; a guard test fails when code reads a key the example doesn't list or the example holds a value

### CI

- **feat** X-26: the `edge` job runs `deno check` (and lint/fmt/test) against the frozen lock; new `ios-build.yml` (weekly, on app changes, manual) regenerates the project with xcodegen and compiles the app and share extension for the simulator unsigned (`CODE_SIGNING_ALLOWED=NO`), no secrets (IOS-11's build half)
- **chore** `deploy-parser.yml` is WIF-only: the `GCP_SA_KEY` fallback is gone (the repo secret was deleted); missing `GCP_WIF_PROVIDER` / `GCP_DEPLOY_SA` fail the configuration check

### Parser

- **fix** SRV-18: the Sentry scrubber (`ccs_parser/sentry.py`) also replaces free-text email addresses with `[email]` (`test_scrubber_removes_free_text_emails`)

### Docs

- ARCHITECTURE §10: email scrubbing and per-request tag isolation
- ARCHITECTURE §2 (`gmail-push`, `statements-upload`, `ops-monitor`, `_shared/provider.ts`), §10 health checks; README env table (`GMAIL_PUSH_BUDGET_MS`, `OPS_QUEUED_DOCUMENT_AGE_S`), ARCHITECTURE §4/§7 (`begin_document_parse`, the `storage_cleanup` consumer) and upload response; PRODUCTION §2.5 optional overrides, §5 push responses
- `member-invite`: README API table, ARCHITECTURE §2, PRODUCTION §2.2 (adding a member) and §2.5 (deploy list)
- docs/ci-cd.md (edge job, `ios-build.yml`, WIF-only parser deploy, `GCP_SA_KEY` deleted, lock refresh how-to), PRODUCTION §2.5 (`.env.example`) and §9, README tests and local setup
- X-32 decision recorded: Vercel Preview deployments are off for `apps/web` (PRODUCTION §4, docs/ci-cd.md §2.3; the switch itself is a Vercel dashboard action)
- docs/audit: BACKLOG rows closed (SRV-05/07/10/11r/14/15/18/19/20/22/23, NEW-1, DB-21e, X-16r, X-26, X-32, FV-04) with remainders NEW-1r (web) and SRV-13r (parser), recounted after the database pass; fix-status notes in 03, 06 and 07

## Passkeys and code-only email sign-in — 2026-10-08 (branch `ledger-v2`)

### Backend (Supabase)

- **feat** Auth email templates as code (`supabase/templates/`, `[auth.email.template.*]`): *Magic Link*, *Confirm signup*, *Invite user*, *Change Email Address* and *Reauthentication* carry a one-time code and no sign-in link; the invite tells people to sign in with their email. Pushed to production
- **feat** `[auth.passkey]` / `[auth.webauthn]` locally (RP ID `localhost`, origin `http://localhost:5173`); production passkeys use RP ID `cc-statement-scraper.vercel.app` (dashboard)
- **fix** `[remotes.production]` pins every setting that differs from local (site URL, redirect URLs, email confirmations, OTP length 8, TOTP MFA, max rows, vector storage), so a `supabase config push` can't overwrite production with local values again (it did once today and was restored within minutes; see PRODUCTION §2.7)

### Web

- **feat** Sign-in is an emailed code or a passkey (`signInWithPasskey`, with passkey autofill in the email field where the browser supports conditional UI). Password and magic-link sign-in removed; `emailCodeOptions()` sends no redirect link and never creates users; codes of 6–10 digits accepted; "Send a new code"
- **feat** After a code sign-in, "Add a passkey?" (Add / Not now). "Not now" is remembered per user in this browser (`data/passkeys.ts`)
- **feat** Settings → Account: signed-in email, sign out, and passkeys (list with created / last used, add, rename, remove)
- **feat** `/.well-known/apple-app-site-association` (webcredentials for `2F94NY8R3T.com.hussu97.ledger`), served as JSON and excluded from the SPA rewrite
- **fix** Rejecting a merchant suggestion calls `reject_merchant_suggestion`, so the nightly LLM pass stops re-suggesting it (WEB-14); the rule preview passes `p_rule_code` when editing, so a rule's own effect isn't counted as a change (DB-31)
- **test** `passkeys.test.ts` (offer rule, Not-now storage, support detection, default names, cancel detection, error sentences, code cleaning)

### iOS

- **feat** Sign in with a passkey (`SessionStore.signInWithPasskey`, supabase-swift `@_spi(Experimental)`), plus the post-sign-in offer (`AppRoute.offerPasskey`, `PasskeyOfferView`) and Settings → Account → Passkeys (`PasskeysView`, `LedgerKit.PasskeyStore`: list, add, rename, remove). Associated Domains `webcredentials:$(LEDGER_PASSKEY_DOMAIN)`
- **fix** The email-code request no longer passes `shouldCreateUser: true`; the Debug password form is gone (the env-driven `DevSignIn` for the local demo user stays, Debug only)
- **test** `PasskeyTests` (offer rule, Not-now flag, cancellation, error sentences, routing)

### Docs

- PRODUCTION §2.2 (code-only sign-in, passkeys, RP ID warning) and §2.7 (auth config as code, the `config push` warning); ARCHITECTURE §8; README sign-in and local passkey testing

## Claude rules and guard hook — 2026-10-08

### Docs

- **chore** `.claude/settings.json` + `.claude/hooks/guard.py`: a Claude Code PreToolUse guard that denies blanket staging (`git add -A`/`.`/`-u`, `git commit -a`), commits without the exact author or with a co-author trailer, printing secret files / env dumps / tokens (Bash and `Read`), dropping or writing the `legacy` schema, `rm -r` of `backend/` or `data/` and `db reset --linked`; and asks before every production action (push to `main`, `db push`, functions deploy, secrets, Vault, Cloud Run, Vercel, `gh secret`/`workflow run`, TestFlight, prod SQL) and hook bypasses. Tested by `guard_test.py` (`python3 .claude/hooks/guard_test.py`). `.gitignore`: `.claude/worktrees/`, `.claude/settings.local.json`
- **docs** CLAUDE.md rules reworked after mm-ecommerce/mm-pos (section numbers kept, since code comments cite them): policy cast explained (§1.5), exact client grants (§1.13), Edge API keys (§3.4), no "iPhone" in App Intent text (§5.6), Sentry off locally + real project slugs (§6), env-var inventory (§8), explicit staging, hooks, `gh` account, `git check-ignore` (§9), fresh-reset pgTAP, `uv`, `pnpm check` (§10), §11 "Production, deploys and secrets" (every production action needs a yes; a push to `main` deploys; `legacy` schema and the untracked `backend/`/`data/` are kept; secret files listed and never printed; publishable key only in clients), §12 workflow (plan first, subagents, lessons loop, enforce don't remember) and §13 guard table
- **docs** Area files `supabase/CLAUDE.md` (migrations, prod shape, policies, Edge keys and secrets) and `apps/ios/CLAUDE.md` (LedgerKit, secrets, App Store/TestFlight rules, verification); `AGENTS.md` pointer; `tasks/lessons.md` seeded with the lessons from this repo's history (incl. `supabase config push`: no dry run, whole file, prod-only values in `[remotes.production]`, code-only email sign-in, passkey `rp_id`) (each with what went wrong, the rule and what enforces it); README links them

## Database audit backlog, P2 and P3 — 2026-10-09

### Backend (Supabase)

- **fix** `20261009000100_db_ledger_fixes.sql`:
  - An SMS held as `unknown_card` is re-processed when a statement registers its card, and its review resolves itself (`private.reprocess_waiting_sms`, called at the end of `ingest_parsed_document`, which now returns `sms_card_registered`) (DB-17r)
  - `overview`'s month-to-date base stops at the end of last month on the 29th–31st (`public.prev_month_to_date_end(p_month, p_today)`) (DB-18)
  - `resolve_merchant` reads before it writes; an existing merchant row is never rewritten (DB-19r)
  - `v_transactions.has_sms` / `has_statement` are scalar sub-queries on the evidence index, evaluated only for the returned page (DB-20)
  - `statement_lines (profile_code, currency_original, txn_date desc)` index for `estimate_fx`; `anomalies` uses window frames instead of two laterals per row, same output (DB-32r)
  - Declined alerts are stored `ignored` (existing rows migrated) (DB-34)
  - An SMS template date more than 7 days from `received_at` falls back to `received_at` and is kept as `parsed_fields.event_at_rejected` (DB-36)
  - Utilisation uses `greatest(closing_balance, 0)` in `overview` and `statement_cycles` (DB-39)
  - New transactions are inserted with their merchant and AED amount, so they are categorised once, not twice (DB-44)
  - `overview.pending_unpriced_count`: pending transactions with no AED amount yet (DB-45)
  - Ingest rejects a statement dated more than 31 days ahead with a permanent `22023` (DP-04r)
  - `transactions.fx_rate` is null for AED (backfilled); a statement `fx_rate` that rounds to 0 is stored as unknown instead of failing the ingest (X-33)
- **test** `13_db_ledger_fixes.test.sql`; `09` and `12` pin `ledger.test_today` for their fixed future dates
- **fix** `20261009000200_db_categorisation_and_jobs.sql`:
  - Seed rules `REST`, `NOON`, `LIME`, `HEALTH`, `BONUS` match whole words (regex), so `INTEREST`, `AFTERNOON`, `SUBLIME` no longer mis-categorise; existing profiles updated where the rule is still exactly as seeded (DB-24)
  - Cashback seeds `MURABAHA PROFIT` and `BONUS` require `direction = credit`: an Islamic-card finance charge is spend again (DP-09)
  - `nightly`, `enqueue_llm_categorize`, `recategorize_stale` and `reestimate_pending_fx` catch errors per profile (per transaction for the FX job) and log them to `private.job_errors` (30-day retention) (DB-25)
  - `generate_insights` produces `spend_pace`, `new_recurring`, `large_transaction` (from `anomalies`) and `review_backlog` (DB-29r)
  - `preview_rule(…, p_rule_code text default null)`: `would_change` follows `recategorize`'s full tie-break and leaves out the rule being edited (DB-31)
  - `public.merchant_category_skips` (`declined` / `rejected`): `apply_llm_suggestions(…, p_merchant_codes text[] default null)` records merchants the LLM declined for the current category set; `public.reject_merchant_suggestion(p_profile_code, p_merchant_code)` drops a suggestion for good; `enqueue_llm_categorize` skips both (DB-37, WEB-14 SQL side)
- **test** `14_db_categorisation_and_jobs.test.sql`; `11_privileges` matrix gains `merchant_category_skips` SELECT
- **fix** `20261009000300_db_sms_templates.sql`:
  - A template change re-processes messages only when the template is live and its pattern, priority, scope or activation changed; only messages its sender pattern (and scope) reaches; newest first, 500 at most. Deactivations and renames re-process nothing (two statement triggers with transition tables) (DB-22)
  - `sms_templates_examples_required`: every template has at least one example (DB-26r)
  - `sms_templates.scope_profile_code`: `propose_sms_template` scopes an LLM template to the proposing profile and builds its sender pattern from `banks.sms_senders` (a message from another sender is `22023`); `private.match_sms_template(…, p_profile_code)` honours the scope; `public.promote_sms_template(p_template_code)` (service role) makes an approved template global (DB-26r)
- **test** `15_db_sms_templates.test.sql`; `02_ledger`'s reversal template gains an example
- **feat** `20261009000400_db_ops_and_worker_rpcs.sql` (SQL side; the Edge Functions wire them up):
  - `ops_health()` adds `mailboxes_stale` (enabled, unsynced > 2 days), `gmail_watch_expiring` (< 24 h or none), `mailbox_errors` (`sync_state.last_error`), each a list of `{mailbox_code, …}` (SRV-10); `job_errors_24h` (DB-25); `open_reviews_total`, `documents_queued_oldest_age_s`; queue metrics gain `newest_age_s` and `total` so a DLQ alert can fire only when a message arrived since the last run (SRV-22)
  - `ops_health()` changes: `recon_failed` and `open_reviews` count the last 7 days, `cron_last_success` scans 7 days (DB-38); `documents_stuck` counts only `parsing` for over an hour, not `queued` (SRV-22)
  - `drain_dlq(p_queue)` and `requeue_dlq(p_queue, p_limit default 100)` (service role; `parse_document` / `llm_categorize` / `sms_fallback`); a re-queued parse message re-opens its failed document (SRV-22)
  - `save_mailbox_sync_state(p_mailbox_code, p_patch, p_last_synced_at, p_watch_expires_at)`: key-wise jsonb merge under a row lock; `gmail_history_id`, `last_synced_at` and `watch_expires_at` never move back (SRV-15)
  - `begin_document_parse(p_doc_code, p_attempt)` claims a document for parsing, or returns `{skip: 'parsed'|'failed'}` for a duplicate or stale message; `resubmit_document(p_profile_code, p_doc_code)` re-queues a failed PDF that is uploaded again; `fail_document` never flips a `parsed` document back (SRV-20)
- **test** `16_db_ops_and_worker_rpcs.test.sql`
- **feat** `20261009000500_db_identity_and_legacy.sql`:
  - `public.delete_profile(p_profile_code, p_confirm_key)` (owner; the key must match): deletes the profile's Vault PDF passwords and mailbox tokens, queues its PDFs on the new `storage_cleanup` queue (`{bucket, paths[]}`, 100 per message) and deletes the profile; `trg_audit` skips rows of a vanished profile, so a user-JWT delete no longer fails on the audit FK (DB-21)
  - Pending invites attach only once the email is confirmed (insert with a confirmed email, or a later confirmation / email change); `add_profile_member` treats an unconfirmed account as not signed up (`invited`) (DB-23)
  - `legacy.*` keeps no table or sequence grants for `anon` / `authenticated` (X-23)
  - `private.legacy_category_aliases` (`Entretainment` → `Entertainment`) used by `apply_legacy_category_choices`; `private.legacy_unresolved_category_names()` lists names that still match no category, for the finalize output (DP-19 / X-24)
- **test** `17_db_identity_and_legacy.test.sql`; `03`, `06`, `07` create confirmed test users
- **test** `18_review_regressions.test.sql`: a line displaced by a manual link keeps its own transaction (DB-27) and an `unknown_card` SMS without a card number is bound to the chosen account (DB-43) (DB-28r)
- **decision** DB-35 (code entropy) and DP-21 (legacy fingerprint collisions) accepted; X-10 (prod `rls_auto_enable()`) left in place; DB-41 no squash (every migration is in production); `amount_drift` stays a reserved review reason; `profiles.timezone` / `base_currency` stay reserved. Not done: DB-40 (needs an accept step, goes with NEW-1), DP-20 (account merge is a model decision), the X-33 `concat_ws` line key (changing it would re-key all stored evidence)

### Docs

- docs/audit/BACKLOG.md: the database P2/P3 items moved to "Done: database pass 2026-10-09"; Edge/Web rows note their SQL side; new DB-21e (drain `storage_cleanup`) and X-33r (iOS `CodingKeys`); summary recounted
- docs/audit/01 Fix status and Appendix A (final definitions after the pass); 02, 03, 04, 06 Fix status notes
- ARCHITECTURE §3–§7: confirmed-email invites, `delete_profile`, template scope and targeted re-processing, `merchant_category_skips`, `storage_cleanup` and DLQ tools, idempotent parse claims, `save_mailbox_sync_state`, insight kinds, batch-job errors, new `ops_health` keys
- PRODUCTION §2.3 (X-10, DB-41, `ledger.test_today`), §2.6 (legacy alias report, DP-21), §11 (DLQ tools, job errors, template promotion, profile deletion)
- README: new RPCs in the RPC table, pgTAP suites 13–18

## Parser P2/P3 audit fixes — 2026-10-08 (branch `ledger-v2`)

### Parser

- **chore** `PARSER_VERSION` and the `pyproject.toml` version 2026.10.2: the fixes below change parser output (NEW-2)
- **fix** FAB `total_credits` includes the credits the summary's Payments/Credits column leaves out (rewards redemptions, dispute credits), taken from the row's own Total Payment Due when it equals the Current Balance. Every local FAB PDF now reconciles debits, credits and balance, including the three statements (19 copies) that were short (DP-10)
- **feat** Mashreq totals from the "Summary AED" block (all six values and the due date), used only when the block is complete and adds up. All 20 local Mashreq PDFs reconcile debits, credits and balance (DP-12)
- **fix** Mashreq foreign rows (`<ref> MYR 500.00 @0.9400 470.00`) report `currency_original`, `amount_original` and the printed `fx_rate`, and the description is the merchant only: 38 lines in the local corpus. Kind and `legacy_fingerprint` are unchanged (DP-11)
- **fix** `EIB_PDF_PASSWORD` and `MASHREQ_PDF_PASSWORD` reach their parsers and the password list used by detection, page counting and totals. The worker already sends every stored key, so no worker or SQL change (X-17)
- **fix** Mashreq `country_code` comes only from an upper-case trailing token, like the other banks (legacy upper-cased any last word)
- **feat** `country_code` is ISO 3166-1 alpha-2 or null (`ccs_parser/countries.py`): alpha-3 codes, `UAE` and FAB's emirate codes (`DXB`, `AUH`, `SHJ`, …) map to alpha-2; `YOU`, `FEE`, `VAT` and other non-codes are null (X-25r)
- **fix** `fx_rate` is `"1"` on every AED line, and null instead of a contract failure for a rate below 1e-8 (X-33, parser part)
- **feat** Wrong bank hint: when the hinted parse fails (layout, decryption, output) or finds no lines and detection names another bank, the parser retries once as that bank and warns; a hinted parse with lines keeps the hint and warns when detection disagrees (SRV-17)
- **test** Synthetic golden set that runs in CI (`tests/test_synthetic_golden.py`): eight fictional statements (FAB, ENBD Dec/Jan year, EIB and Mashreq encrypted, ADCB, SIB history, a wrong hint) built as PDFs at test time and compared with committed snapshots (SRV-24)
- **test** `tests/synthetic/versions.json` records the snapshot digest per `PARSER_VERSION`: changed output under a recorded version fails the suite, and `python -m tests.synthetic.update` refuses to record it (NEW-2). A test pins `pyproject.toml`'s version to `PARSER_VERSION`
- **chore** Supply chain (SRV-13, parser part): `requirements.txt` with hashes (`uv pip compile --generate-hashes`), installed with `pip --require-hashes --only-binary=:all:`; base image pinned by digest; plain `uvicorn` without the `[standard]` extras; the image copies `ccs_parser/` instead of pip-installing it (no unpinned build backend). Built and run locally: `/health` and `/parse` OK
- **docs** Capacity measured, `--concurrency 4` kept (SRV-12): a parse peaks at 150-180 MB; four concurrent parses peaked at 444 MiB and took 14 s on one vCPU
- **test** `tests/synthetic_pdf.py` (dependency-free PDF writer) and fictional statements in `tests/synthetic/cases.py`; `test_pdf_passwords.py`, `test_mashreq_fx.py`, totals cases

### Docs

- parse-v1: password keys, totals per bank, Mashreq foreign rows, bank-hint retry, `fx_rate`, `country_code`, versioning; parser README; BACKLOG (DP-10, DP-11, DP-12, X-17, SRV-17, X-25r, SRV-24, NEW-2, SRV-12 done; SRV-13 parser part done; X-33 parser part done; NEW-4 Mashreq `card_last4` is the card's BIN); 02, 03 and 06 fix status; PRODUCTION §3 capacity note

## Supabase publishable / secret API keys — 2026-10-08 (branch `ledger-v2`)

### Backend

- **feat** Edge Functions prefer the new API keys: `_shared/supabase.ts` resolves the secret key from the runtime-injected `SUPABASE_SECRET_KEYS` (JSON, `default`), then the custom secret `SB_SECRET_KEY`, then the legacy `SUPABASE_SERVICE_ROLE_KEY`; the publishable key likewise (`SUPABASE_PUBLISHABLE_KEYS` → `SB_PUBLISHABLE_KEY` → `SUPABASE_ANON_KEY`). User clients still forward the caller's JWT. The service client logs its key source (name only). Prod and local both resolve to `SUPABASE_SECRET_KEYS`, so no custom secrets were added
- **test** `api_keys_test.ts` (resolution order, malformed JSON, no values in errors); `e2e_local_test.ts` uses `PUBLISHABLE_KEY` / `SECRET_KEY` from `supabase status`

### Web

- **feat** `VITE_SUPABASE_ANON_KEY` → `VITE_SUPABASE_PUBLISHABLE_KEY` (`lib/supabase.ts`, setup error, `.env.example`); `lib/supabase-key.ts` refuses an `sb_secret_` key so it can never ship to the browser (`supabase-key.test.ts`). supabase-js 2.117.3 (latest) already supports the new keys; Realtime authenticates with the user's JWT
- **chore** Vercel env: `VITE_SUPABASE_PUBLISHABLE_KEY` (production + preview) added, `VITE_SUPABASE_ANON_KEY` removed

### Scraper

- **feat** `CCS_SCRAPER_SUPABASE_ANON_KEY` → `CCS_SCRAPER_SUPABASE_PUBLISHABLE_KEY` (`ScraperConfig.supabase_publishable_key`, `ScraperClient(publishable_key=)`); the old name is a deprecated fallback with a `DeprecationWarning`

### Docs

- PRODUCTION §2.8 (key map and the checklist for disabling the legacy JWT keys), §2.5/§2.7/§4/§10 key names; README env tables and setup; ARCHITECTURE §8 API keys; scraper README

## Bank Ledger iOS on TestFlight — 2026-10-08 (branch `ledger-v2`)

### Frontend (mobile)

- **fix** App Intent description no longer says "iPhone" (App Store processing rejected build 2 with ITMS-90626)
- **fix** A stored session the server rejects (`notSignedIn` while loading ledgers) now signs out locally instead of leaving a signed-in "Couldn't load — You are signed out" screen (`ProfileStore.sessionRejected`, test in `AppRouteTests`)
- **feat** Supabase publishable key: `LEDGER_SUPABASE_ANON_KEY` / `LedgerSupabaseAnonKey` → `LEDGER_SUPABASE_PUBLISHABLE_KEY` / `LedgerSupabasePublishableKey` (xcconfigs, Info.plists, `LedgerConfig.supabasePublishableKey`, `StatementUploader(apiKey:)`); `LedgerConfig` refuses an `sb_secret_` key. supabase-swift 2.55.3 (already validates the new key format)
- **feat** Brand icon (`assets/brand/ios/AppIcon-1024.png`) and "Bank Ledger" in the remaining product strings (unconfigured screen, share extension, Settings SMS copy)
- **chore** `testflight.sh` uploads dSYMs to the DSN's Sentry project id when `SENTRY_PROJECT` is unset (the `ledger-apps` slug returned "Project not found"); `ASC_SIGN_WITH_KEY=1` optionally signs with the API key
- **chore** App Store Connect: app "Bank Ledger" (6820524042), groups "Bank Ledger Internal" (automatic) and "Friends & Family" (public link), Test Information and review contact set

### Docs

- apps/ios/README.md, README.md, PRODUCTION.md: publishable key, Bank Ledger naming, TestFlight groups

## Bank Ledger rebrand and SMS setup guide — 2026-10-08 (branch `ledger-v2`)

### Web

- **feat** Brand mark (a ledger column closed by a double rule) drawn from tokens: `BrandMark` / `BrandLockup` in the sidebar, mobile header, splash, sign-in and privacy page; product copy says "Bank Ledger" everywhere (the *ledger* entity keeps its name)
- **feat** Favicons (SVG, dark-mode aware; 16/32 PNG), `apple-touch-icon.png`, maskable `icon-192/512.png` and `site.webmanifest` (name, theme/background colours from tokens), wired in `index.html` with description, app-name and per-scheme `theme-color` meta; CSP unchanged (all `'self'`)
- **feat** Settings → iPhone SMS rewritten as a step-by-step guide for the one "Log Bank SMS" automation: prerequisites, 10 steps with mock-ups of the exact field values, copy buttons for `Card` and `Log Bank SMS`, *Open Shortcuts app* (iOS only), a client-side QR code to open the guide on the phone (desktop), optional TestFlight button (`VITE_TESTFLIGHT_URL`), how to test, banner meanings, troubleshooting and the privacy note
- **test** `brand.test.ts` (mark geometry = source SVG, favicon/manifest/index.html colours = tokens, linked icons exist), `sms-guide.test.ts` (UA detection incl. iPadOS, TestFlight URL validation, step integrity, keyword and action name pinned to the Swift sources), `qr.test.ts`
- **chore** dependency `uqr` (QR encoding, no runtime deps)

### Docs

- README, ARCHITECTURE, PRODUCTION, CLAUDE.md say "Bank Ledger"; `VITE_TESTFLIGHT_URL` documented (README env table, PRODUCTION §4, `.env.example`); PRODUCTION §2.7 lists the dashboard settings that still say the old name (Auth email templates, SMTP sender name, Google/Microsoft consent screens, App Store Connect name)
- **chore** `assets/brand/bank-ledger-mark.svg` + `scripts/brand/generate-icons.mjs` (`pnpm brand:icons[:check]`, root devDependency `@resvg/resvg-js`) render every icon, including the opaque `assets/brand/ios/AppIcon-1024.png` staged for the iOS asset catalog

## CI/CD follow-ups — 2026-10-08 (branch `ledger-v2`)

### Backend (Supabase)

- **style** `deno fmt` on `supabase/functions` (19 files, formatting only; lint and 91 tests unchanged); `deno fmt --check` is now blocking in `ci.yml` (`edge`) and the pre-push hook (the unused advisory helper is gone)

### Docs

- PRODUCTION.md §9 and README hooks/CI section point to docs/ci-cd.md and describe `ci.yml` + `ci-ok`, `deploy-supabase`, `deploy-parser`, `web-smoke`, `ios-testflight`, pre-commit (fast) / pre-push (full) and `SKIP_PRE_PUSH` / `SKIP_RELEASE`; `LEGACY_DEPLOYS_ENABLED` noted as deletable

## Legacy v1 removed — 2026-10-08 (branch `ledger-v2`)

The cutover is complete, so the legacy v1 code is deleted (it stays in git history). The
`legacy` database schema and the migrations that reference it are untouched.

### Backend (Supabase)

- **chore** Removed `backend/` (FastAPI + embedded worker, Alembic, Gmail/MS ingest scripts; 189 files), `deploy/` (legacy Dockerfiles, compose, Caddyfile, nginx, network policy) and the root `.dockerignore` (only legacy images built from the repo root; the parser has its own)
- **chore** Removed the one-off cutover script `scripts/migrate_legacy.py` and `scripts/tests/`; `scripts/cutover/` (Edge and Vault secret helpers) stays for rotations

### Parser

- **chore** Removed `scripts/build_golden.py` and `scripts/_legacy_runner.py`, which ran the legacy parser from `backend/.venv`. The local golden fixtures are now a frozen legacy snapshot (not regenerated from the current parser); `test_golden_parity.py` still runs against them with the same allowed deltas

### Web

- **chore** Removed the legacy React admin `frontend/` (66 files) and its `.gitignore` entries

### Docs

- README, ARCHITECTURE, CLAUDE.md layout: legacy rows and sections replaced by a short "Legacy v1 (removed)" note; PRODUCTION.md §10 is now a cutover record with the remaining out-of-repo decommission checklist (Render, legacy Vercel project, Gmail relay, GCS, `LEGACY_DEPLOYS_ENABLED`), §9 without legacy workflows and a merge-timing warning (legacy Git-connected builds must be off before `main` loses `backend/`/`frontend/`), and the post-import statement-date check moved to §11 Operations; removed the legacy `docs/operations/` and `docs/security/`; parser README documents the frozen golden fixtures; BACKLOG drops the findings that only concerned the removed cutover script (SRV-09r, DP-17); ROADMAP marks the code removal done

## Ledger iOS TestFlight pipeline — 2026-10-08 (branch `ledger-v2`)

### Frontend (mobile)

- **feat** TestFlight release flow mirroring mm-pos: `apps/ios/scripts/testflight.sh` (test, archive, export, dSYMs → Sentry, altool upload with the App Store Connect API key, `--no-upload`, `--keep-build`), `publish-build.sh` now stages the IPA + `build-meta.json` on the `ios-ledger-staged` release and commits the spent build number, and `testflight-distribute.mjs` waits for processing, sets "What to Test", attaches the build to "Friends & Family" and submits it for Beta App Review
- **chore** Registered bundle ids `com.hussu97.ledger` and `com.hussu97.ledger.share` in the developer portal with App Groups enabled

### Docs

- apps/ios/README.md: TestFlight groups, scripts, credentials and the staged-build contract for CI

## Final-verification fixes — 2026-10-08 (branch `ledger-v2`)

Fixes for [docs/audit/07-final-verification.md](docs/audit/07-final-verification.md) FV-01…FV-04.

### Backend (Supabase)

- **fix** Client grants no longer depend on the database's default privileges (FV-01, blocking): `…0000` now starts by revoking `postgres`'s default privileges on `public` tables and sequences from `anon`/`authenticated` (production still has Supabase's older `GRANT ALL` defaults), and the new final migration `…2100_reassert_client_grants` revokes everything from both roles on `public` and replays the intended grants. On prod defaults `anon` would otherwise get full table rights, `authenticated` table-wide INSERT/UPDATE/DELETE (bypassing the column-level UPDATE limits) and `service_tokens.token_hash` would be readable. Also closes DB-30 (TRUNCATE/REFERENCES/TRIGGER/MAINTAIN revoked)
- **fix** Re-parse relink (FV-02, `…2000`): `match_statement_lines` prefers a line's own previous transaction (same line, same `line_key`+`occurrence`, or same source document with the same date and amount) and resolves same-amount purchases on consecutive days by date proximity, so a corrected statement date no longer holds them as `ambiguous`
- **fix** Stale reviews (FV-03, `…2000`): a trigger on `statements` dismisses open reviews about a statement that stops being active and any `period_overlap` review left with no active candidate; existing stale reviews are dismissed once
- **test** pgTAP `11_privileges` (default privileges, no `anon` rights, column-limited `authenticated` UPDATE, `token_hash`, exact client privilege matrix) and `12_final_verification` (FV-02/FV-03 regressions). 12 files, 533 assertions; also passes on a stack emulating production's default privileges

### Docs

- PRODUCTION.md: rehearsals start from `supabase db reset`, and how to rehearse against prod's grants (FV-04); ARCHITECTURE.md: explicit client grants, re-parse lineage, stale review dismissal; BACKLOG.md: FV-04 CI guard added, DB-30 removed

## Audit fixes (pre-cutover) — 2026-10-08 (branch `ledger-v2`)

Fixes for the P0 and P1 findings of the six pre-cutover audits in `docs/audit/` (01 database,
02 data parity, 03 server, 04 web, 05 iOS, 06 cross-cutting), plus the P2/P3 items fixed along
the way. IDs refer to those reports. Everything not yet fixed is listed in
[docs/audit/BACKLOG.md](docs/audit/BACKLOG.md).

### Backend (Supabase)

- **fix** Tenant integrity is structural (DB-01, DB-02, DB-03, DB-14; migration `…1500`): every parent has `UNIQUE (profile_code, code)` and every child references it through a composite FK (cards, statements, lines, SMS, transactions incl. related/rule/recurring, evidence, reviews, recon, email routes). `resolve_review`'s card branch only accepts an account of the review's profile and bank; `supersede` only an open candidate of the review on the same profile and account, never the subject (DB-33). Matcher candidate joins are on `(profile_code, account_code)`
- **fix** No data loss from extra documents (DP-01, DP-02, DP-06): `statement_lines.source_doc_codes` records which documents contain each line. A document only withdraws its own evidence, so a card-less ADCB companion PDF or a shorter SIB history window can no longer supersede lines; only a re-parse of the same document can. A card-less statement without rows is skipped with a document warning. Real-data replay: ADCB line coverage 80.8 % → 100 %, SIB 53.2 % → 100 %, orphaned reviews 150 → 0
- **fix** Re-parsing a document whose statement date or account changed retires the old statement instead of duplicating the ledger; a later re-parse that produces it again revives it with its codes (DB-06)
- **fix** A statement without a card number never invents an account: same document → its account, then the bank's only active account, then an explicit reference seen on one account, else a permanent `22023` (DB-07)
- **fix** `ingest_sms` validates and processes each message on its own: `invalid` (+ `reason`), `failed` (`error:<sqlstate>`, message kept), `duplicate_delivery`, `rejected_otp` or the processing outcome; one bad SMS never fails the batch. An impossible template date means "template doesn't apply". The template re-process trigger isolates errors too (DB-08)
- **fix** Rule `conditions` are validated on write (known keys, numeric amounts, existing bank, own card, ISO currency, kind, direction) by `private.rule_problem` in the trigger and `preview_rule`; evaluation uses `private.safe_numeric`, so a bad rule can't stop ingestion (DB-09)
- **fix** The matcher no longer calls separable pairs ambiguous: a competitor ≥ 0.3 below on merchant affinity isn't a conflict (DB-10)
- **fix** Ingestion and review resolution take a per-profile advisory lock (`private.lock_profile`) first, so the bulk legacy import can't create duplicate accounts or cards or deadlock (X-08, DB-42, DP-15)
- **fix** Function-level `statement_timeout` removed (it never applied); regex cost bounded on write instead: rule patterns ≤ 200 chars, template patterns ≤ 1000/200, no back-references, SMS bodies ≤ 2000 chars (DB-13)
- **fix** Merchants and aliases are readable only when the caller's profiles reference them; SMS templates only for the caller's banks, messages or proposals; `sms_templates.examples` is not granted to clients (DB-04)
- **fix** Self sign-up disabled (`[auth] enable_signup = false`, DB-04 / WEB-04); members join by invite. The legacy import refuses to adopt a profile key it did not create (`private.legacy_import_profiles`, DB-05)
- **fix** `legacy_parity_report(p_schema)` casts the legacy `varchar`/enum columns and adds `legacy_lines_missing` / `legacy_aed_missing`; `private.legacy_missing_lines()` lists lost lines (DB-11, X-02, DP-05)
- **fix** Legacy category choices are evaluated once per transaction and never re-applied over a user edit; `ledger-legacy-choices` unschedules itself when nothing is pending or 30 days after staging; `private.legacy_unmatched_choices()` lists leftovers (DB-12)
- **fix** Reconciliation: lines without an AED amount count at their printed rate and downgrade an explained mismatch to `warn` (`unpriced_lines`, DB-16 / X-18); history extracts get `n/a`; an empty statement whose header shows activity, or whose lines were all withdrawn, is `warn`, never `ok` (DP-08)
- **fix** Two alerts with different available limits are never duplicates (DB-15); `missing_from_statement` reviews resolve once the transaction stops being pending (DB-17, partly); a line displaced by a manual link gets its own transaction and linking onto a locked line is refused (DB-27); resolving `unknown_card` for an SMS without last4 binds it to the chosen account (DB-43); orphan reviews raised and resolved in one transaction are dropped (DP-06)
- **perf** The matcher resolves each line's merchant once (DB-19, partly); indexes on `transactions.stmt_code`, `related_txn_code`, `rule_code` and `statement_lines(profile_code, legacy_fingerprint)` (DB-32, partly)
- **feat** Migration `…1900`: `retry_sms_fallback` (owner re-asks the LLM for an unparsed SMS), `merchant_search` (every merchant of a profile, not limited by spend), `statement_cycles` `p_limit` up to 5000, `resolve_review {"not_a_transaction": true}`, and distinct seed colours for Medicine, Forex Charge and Apple in-app purchase
- **chore** `ledger-cron-history-purge` deletes `cron.job_run_details` older than 7 days (X-11); local `[api] max_rows = 2000` (X-07)
- **test** pgTAP `08_tenant_isolation` (negative cross-profile tests), `09_ingest_robustness`, `10_web_review_and_search`; `02` and `03` are hermetic and `03` mocks the legacy schema with the real `varchar`/enum types (DB-28, X-31). 10 files, 503 assertions
- **fix** Edge `worker`: only a 422 carrying a contract permanent code is permanent; every other parser response (401/403/404/400/413, a 422 without a known code, a 200 without parse-v1, 5xx, timeouts) is retried with backoff (60 s / 5 min / 15 min / 30 min) and dead-lettered after 5 attempts, with error-level Sentry events per status (SRV-03). Ingest SQLSTATE class 22, `23502` and `23514` are permanent; the event carries the SQLSTATE and constraint with literal values filtered (X-06)
- **fix** Edge `worker` time budget: a round starts only if it fits the Edge wall clock (`EDGE_WALL_CLOCK_MS`, 150 s); `PARSER_TIMEOUT_MS` defaults to 75 s (was 100 s), above the parser's 60 s kill (SRV-04)
- **fix** `statements-upload` caps a request at 40 MB, enforced on `content-length` and while streaming chunked bodies, before form parsing (SRV-06)
- **fix** SMS fallback: a non-transaction message (`msg_kind=other`, null amount) is skipped without a DLQ entry; deterministic failures dead-letter once with a sanitised reason; no LLM call without banks (`NO_BANKS`); SDK retries off (the queue retries)
- **fix** Edge Sentry never initialises when `SENTRY_ENVIRONMENT` is unset, `local`, `development` or `test`, even with a DSN (`sentryActive`)
- **test** deno: `worker_test.ts` (parse state machine, DLQ, budget, backoff, upload body cap), `sentry_local_test.ts`. 91 pass
- **fix** `scripts/migrate_legacy.py`: `--target local|prod` is required and checked against `LEDGER_DB_URL`/`SUPABASE_URL`; `--apply` against prod also needs `--yes-i-mean-prod <ref>` (DP-13). Legacy PDFs carry their known bank as `documents.bank_code`; an insert conflict deletes the uploaded object; a missing profile exits with a clear message; differing OAuth app credentials across profiles warn (SRV-09). `scripts/tests` 12 pass

### Parser

- **fix** Resource limits (SRV-01): every parse runs in a killable forkserver child (30 s CPU, 60 s wall, 768 MB address space on Linux, 32 MB inflated streams); PDFs over 15 MB or 30 pages are rejected before extraction. A 65 KB crafted PDF that took 202 s is now rejected in 0.2 s. New permanent 422 codes `PARSE_TIMEOUT` and `PDF_TOO_LARGE`
- **fix** Output validated against the DB's constraints before it is returned (X-06): real dates (2000–2100), `period_start ≤ period_end`, statement period ≤ 100 days, due date 0–120 days after the statement date, 4-digit last-4 (malformed values become null), `txn_time`, `numeric(14,2)` amounts, `fx_rate > 0`. A violation is the permanent 422 `PARSE_OUTPUT_INVALID` (field paths only)
- **fix** ENBD/EIB statement years come from the full Statement Date (else the newest posting date), so Dec/Jan statements no longer fail or land a year in the future: 38 lost lines recovered (DP-03, DP-04)
- **fix** FAB rows with an original amount in decimal-comma (`EUR 108,99`) or 3-decimal (`KWD 18.750`) format were skipped; both affected statements now reconcile (DP-07)
- **fix** Bank detection scores every bank on legal-name and brand markers outside transaction rows, so "TRANSFER EMIRATES NBD" on a FAB statement no longer wins (SRV-08)
- **fix** Parser Sentry never initialises for an unset, `local`, `development` or `test` environment (`sentry_active`)
- **test** `test_limits.py`, `test_output_validation.py`, `test_upload_bank_detection.py`; golden parity allows the ENBD year and FAB line deltas explicitly. 272 pass (92 golden cases on the private corpus)

### Web

- **fix** Out-of-range pages clamp to the last page instead of "Requested range not satisfiable" (WEB-01); statements, documents and reviews paginate server-side with exact counts, health counts use head counts, and Merchants lists every assigned or suggested merchant beyond the top 200 (WEB-02, partly)
- **fix** The Review nav badge is a head count gated on session and profile (fixes "permission denied for table match_reviews" sent with the anon key); the Supabase Sentry integration no longer re-reports every failed request
- **fix** Sentry spans are scrubbed (`beforeSendSpan`; `beforeSendTransaction` was ignored by streamed spans, WEB-03); Sentry never initialises for an empty, `local`, `development` or `test` environment or in Vite dev mode
- **fix** Magic links never create users (`shouldCreateUser: false`); an unknown email is told to ask for an invite (WEB-04)
- **fix** A foreign amount without an FX rate shows in its own currency with "awaiting FX" instead of as AED (WEB-05)
- **fix** An unparsed SMS without a proposed format can be marked "Not a card transaction" or dismissed (WEB-07)
- **fix** Tokens meet WCAG AA: darker light `muted`/`subtle`/`accent`/`warn`, lighter dark `muted`/`subtle`, a 12-hue chart palette with every pair ≥ 15 ΔE2000 and ≥ 3:1; `packages/tokens/test/contrast.test.mjs` enforces the declared pairs (WEB-06, WEB-29). axe colour-contrast nodes 781 → 0 on the walked screens. `Tokens.swift` regenerated
- **feat** Insight cards link to their screen (WEB-25); Review replaces Cards in the mobile bottom bar with a count (WEB-23); 44 px hit areas below `lg` (WEB-22, partly); "Clear filters"/Back resets the search box (WEB-08); every Trends label shows on mobile (WEB-18); reduced motion stops infinite animations (WEB-21); expired insights are hidden (WEB-45)
- **feat** Adopts the post-audit DB contracts: "Not a card transaction" sends exactly `{not_a_transaction: true}` (it was also sending `dismiss`, so the SMS was never marked), and also applies to unknown-card SMS; "Retry AI" on an unparsed SMS (`retry_sms_fallback`, WEB-07); friendly P0002/22023 review errors; Rules → Merchants searches and pages server-side through `merchant_search`; Statements page up to 5000 cycles (WEB-02); recon `n/a` shows as a neutral "Nothing to reconcile" with the unpriced / no-lines checks explained; document parse warnings shown with digits masked
- **test** `src/test/audit-fixes.test.ts`, `db-contract.test.ts`, `sentry-scrub.test.ts`, `sentry.test.ts` wiring tests. 159 pass

### iOS

- **fix** Sentry never starts for `LEDGER_ENVIRONMENT` local/development/dev/test or Debug builds, even with a DSN (`Telemetry.shouldStart`)
- **fix** SMS outbox can no longer wedge (IOS-01): failures are classified (`LedgerAPIError.kind`: 42501/22xxx/23xxx/P0xxx/PGRST1-2xx/4xx permanent; network, 5xx, 57014, 08/40/53xxx transient; 401/PGRST3xx signed out). A permanently failing batch is split until the bad message is alone; a permission error parks that ledger's batch; per-message `invalid`/`error` statuses (newer `ingest_sms`) park only that message; transient retries stop after 8 attempts. Parked messages are listed in Settings → "Not sent" with Retry (to the current SMS ledger) / Delete. Flushes in one process are serialised. Shortcut results say why a message waits (offline / signed out / server) instead of always "when you're back online"
- **feat** Explicit "SMS go to" ledger (IOS-02): owned ledgers only, defaults to the first owned one, stored in the App Group; the App Intent and the Share Extension (which now shows "Uploading to …") use it instead of the last-viewed ledger. Viewers no longer see the statement upload card
- **fix** One due-date rule for Overview and Statements (`DueStatus`, IOS-03): past due dates read "Was due 25 Sep"; "Overdue" only for an account's latest statement with no payment detected (not detectable on the phone yet, so never shown)
- **fix** Overview hero (IOS-04) renders the server's `change_vs_prev_month_to_date` ("52% below the same day last month") and per-account `utilisation`; the 3-month average is shown as a plain figure (it is a full-month average) and only used as a ratio for completed months. Overview no longer fetches `statement_cycles`
- **fix** Dynamic Type (IOS-05): the hero number scales with `@ScaledMetric` and stacks under its unit when needed; pending strip, ring card, card, statement, upload and Activity rows stack from xxxLarge (`AdaptiveRow`); money stays on one line (`moneyLine()`); chips wrap between words and cap at accessibility2; labelled filter and 44 pt dismiss buttons
- **feat** SMS setup guide (IOS-06): one automation on "Card" (present in every ADCB/FAB/ENBD/SIB card alert in the template seed), keep "Notify When Run" on; Settings and the guide show "Last captured" and a "Send test" that runs the intent's path with a synthetic non-transaction message
- **feat** Review screen (IOS-07) from Overview → Needs attention: open `match_reviews` with link to candidate / keep as new / dismiss, and register an unknown card to an account of the same bank (`resolve_review`); read-only for viewers. Shortcut results for `unknown_card`/`held` point to it
- **feat** `PrivacyInfo.xcprivacy` in the app and the share extension (IOS-08): UserDefaults (1C8F.1, CA92.1), crash data only, no tracking
- **fix** A sign-in whose session couldn't be saved to the keychain is no longer shown as signed in (IOS-09); Debug builds keep the session in memory instead, and the no-access-group keychain fallback is Debug-only
- **chore** `scripts/publish-build.sh` reads `SENTRY_AUTH_TOKEN` / `SENTRY_ORG` / `SENTRY_PROJECT` from the environment or `Config/Secrets.Release.xcconfig`, passes the token via the environment and never prints it
- **chore** `Tokens.swift` regenerated from the AA-contrast tokens (with the web change)
- **feat** Adopts the post-audit DB contracts: Review offers "Retry AI" (`retry_sms_fallback`) and "Not a card transaction"; the outbox parks per-message `invalid`/`failed` statuses with readable reasons; recon `n/a` decodes
- **test** `AuditFixTests`, `OutboxFailureTests`, `DBContractTests` and decoding fixtures for the new `overview` and `ingest_sms` shapes. 114 pass

### Scraper

- **fix** Uploads are split into requests of ≤ 20 files and ≤ 32 MB (`CCS_SCRAPER_UPLOAD_MAX_FILES` / `CCS_SCRAPER_UPLOAD_MAX_MB`, clamped to the server's limits); a 413 halves the batch; a partial failure raises `UploadBatchError` and the batches that succeeded are recorded, so `upload-pending` retries only the rest (SRV-02). 135 tests pass

### Docs / CI

- **docs** `docs/audit/01`–`06`: database, real-data parity (aggregates only), server, web, iOS and cross-cutting audits, each with a Fix status. `docs/audit/BACKLOG.md` collects every finding and recommendation not yet fixed, with a "do before / at cutover" list
- **docs** PRODUCTION.md runbook: function and Vault secrets from one gitignored source (`scripts/cutover/set-edge-secrets.sh`, which refuses placeholders and never echoes, and `set-vault-secrets.sql`) (X-01, X-04); Gmail OAuth client copied from Render (X-03); ordered legacy disable list and rollback (X-13); dashboard settings: Postgres upgrade, API max rows 2000, sign-ups off (X-07); `supabase migration list --linked` before `db push` (X-09); Vault set only after functions deploy (X-21)
- **docs** PRODUCTION.md after the fixes: `migrate_legacy.py --target prod`, dry run first, `--yes-i-mean-prod nkmylznisjcnmqbxosey` for writes (zsh-safe); members added via Supabase Auth → Invite user with sign-ups off; parser limits and nested timeouts (60 s < 75 s < 120 s) on Cloud Run in `credit-card-scraper-ht` / `me-central1`; Sentry off for local/dev/test in every runtime; post-import ENBD/FAB checks with SQL to requeue and supersede a stale bad-year statement; parity sign-off on `legacy_lines_missing = 0`; rotate the exposed Anthropic key and Sentry org token
- **docs** parse-v1: the full error table (`INVALID_REQUEST`, `PARSE_TIMEOUT`, `PDF_TOO_LARGE`, `PARSE_OUTPUT_INVALID`, 502 `DOWNLOAD_FAILED`, 500 `INTERNAL_ERROR`), output validation rules, resource limits, and code-based worker classification (SRV-21, X-25)
- **docs** ARCHITECTURE: composite FKs, per-profile ingest lock, multi-document line union, recon `n/a`, per-message `ingest_sms` statuses, iOS outbox classification and "SMS go to", no self sign-up, local-off Sentry; removed the stale "120 s statement timeout" and "regex runs under a statement timeout" claims (DB-13) and the insight kinds that are never generated (DB-29). README: env vars (`PARSER_TIMEOUT_MS` 75000, `EDGE_WALL_CLOCK_MS`, parser limits, scraper batching, Sentry local behaviour), `docs/audit`, new RPCs and screens. ROADMAP: audit row and remaining cutover tasks
- **ci** `ci.yml` `changes` job gets `pull-requests: read`, so PR runs no longer fail on the paths filter (X-05); legacy workflows run only while the repository variable `LEGACY_DEPLOYS_ENABLED` is `true` (X-13); `deploy-supabase` and `deploy-parser` refuse any ref but `main` (X-12)
- **chore** The parser deploys to `credit-card-scraper-ht` / `me-central1`, Artifact Registry repo `ledger` (X-29); `services/parser/.gcloudignore` and `.dockerignore` keep `.env*`, `.venv` and tests out of the upload and image (X-15)
- **chore** Git hooks skip missing `backend/`/`frontend/` and tools, `pre-push` runs the v2 checks, `commit-msg` rejects `Co-Authored-By` (X-14)

## Ledger v2 — 2026-10-08 (branch `ledger-v2`)

A rebuild around Supabase. The DB and business logic move into Postgres, ingress and I/O into
Edge Functions, and parsing into a stateless Cloud Run service. There is a new web app, a new
iPhone app with real-time SMS capture, and an evidence-based ledger reconciled against
statements. Legacy `backend/` and `frontend/` are frozen until cutover (PRODUCTION.md §10).
Later v2 follow-ups are listed under [Unreleased] below.

### Backend (Supabase)

- **feat** Schema in `supabase/migrations`:
  - Tenancy: `profiles`, `profile_members` owner/viewer, profile-scoped `service_tokens`.
  - `authz` RLS helpers on every table. RPCs guard in-body (`assert_member` /
    `assert_service_role`); there is no `REVOKE EXECUTE`, because of the PG 17.6.1.104 segfault.
  - Codes as PKs, text + CHECK statuses, numeric money, Dubai dates.
- **feat** The first migration moves every legacy table and enum into a `legacy` schema, so v2
  lives in the existing `cc-statement-scraper` project.
- **feat** Documents, statements and immutable statement lines. Line identity is
  `(line_key, occurrence)`, so identical same-day purchases stay distinct.
- **feat** Canonical `transactions` derived from `transaction_evidence` (statement line >
  history line > SMS).
- **feat** Deterministic scored matcher:
  - amount, date, merchant trigram and card components
  - auto-link ≥ 75 with a 15-point margin, review 55–75
  - interchangeable ties, FX estimates, pre-auth tolerance
  - reversals and released-authorisation voiding
  - in-place re-ingest diffing with orphaning instead of deletes
  - SIB history extracts as separate evidence, never double-counted
- **feat** Statement reconciliation (totals, balance equation, SMS coverage, missing-from-statement)
  and a match review inbox.
- **feat** Dynamic categorisation:
  - generated `effective_category_code` (manual > merchant manual > rule > LLM)
  - set-based `recategorize`, with triggers on transactions, rules and merchant choices
  - `rules_version` sweep every 3 h
  - `preview_rule`
  - defaults seeded once per profile
- **feat** One spend definition, `v_spend`, and analytics RPCs: `overview`, `spend_series`,
  `category_breakdown`, `merchant_leaderboard`, `daily_spend`, `hour_weekday_pattern`,
  `fx_spend`, `statement_cycles`, `yoy_compare`, `anomalies`, `filter_meta`, `budget_status`
  and `recurring_list`.
- **feat** Budgets, recurring-charge detection, a nightly insights feed and an audit trail.
- **feat** Background plumbing:
  - pgmq queues (`parse_document`, `llm_categorize`, `sms_fallback`, each with a DLQ)
  - Vault secrets (PDF passwords, mailbox refresh tokens, `project_url` / `edge_cron_secret`)
  - pg_cron schedules
  - Realtime on transactions, SMS, documents, reviews and insights
- **feat** Data-driven `sms_templates` that reject templates whose examples don't parse and
  re-run unparsed messages on change. 25 real templates for ADCB, FAB, ENBD and SIB, including
  known non-transaction alerts classified as ignored.
- **feat** Daily `fx_rates` fallback for pending foreign-currency SMS (statement rate → USD peg
  → market rate).
- **feat** Legacy import: `private.import_legacy_metadata`, staged legacy category choices
  re-applied nightly, `legacy_parity_report`, and pending member invites claimed on sign-up.
- **feat** Edge Functions, all wrapped in `withSentry` with in-function auth:
  - `statements-upload` (legacy scraper multipart contract or user JWT, sha256 dedup)
  - `sms-ingest`
  - `worker` (parser → `ingest_parsed_document`; Claude categorisation and SMS-template proposals)
  - `gmail-push` (OIDC-verified), `gmail-watch-renew`, `outlook-poll` (Graph delta, resumable)
  - `ops-monitor` (ops health → Sentry, `ops-heartbeat` cron check-in)
  - `fx-rates`
- **test** pgTAP suites (RLS and security guards, ledger and matching, legacy import, SMS
  templates, FX) and deno tests (auth, upload, worker, email routes, LLM, Sentry scrubber,
  `withSentry` guard, opt-in local e2e).

### Parser

- **feat** `services/parser`: stateless FastAPI `POST /parse` for Cloud Run, implementing
  `docs/contracts/parse-v1.md`.
  - Copies of the legacy FAB, ADCB, ENBD, EIB, SIB and Mashreq parsers.
  - Adds decimal-string money with direction, the `interest` kind, `fx_rate`,
    `legacy_fingerprint`, statement identity and best-effort totals.
  - `X-Parser-Secret` auth that fails closed, a download host allow-list and size limit, and a
    Sentry scrubber.
- **test** Unit tests, ported legacy tests and golden parity tests against the legacy parsers.

### Web

- **feat** `apps/web`: Vite + React 19, TanStack Router/Query, supabase-js with Realtime,
  Tailwind v4 on `@ledger/tokens`, owned Radix components, Recharts with stable category
  colours, Fraunces/Inter, light/dark, responsive to 390 px.
- **feat** Screens:
  - Overview
  - Activity (URL-synced filters, evidence timeline, inline, bulk and merchant categorisation)
  - Insights (trends, categories, merchants, subscriptions, FX, heatmaps, YoY, anomalies)
  - Budgets
  - Cards & Statements
  - Review inbox
  - Rules (live impact preview)
  - Settings (sources and health, tokens, PDF passwords, members, SMS setup)
- **feat** Single data layer in `src/data` (ESLint-enforced), Sentry with a scrubber, and a no-hex
  guard.
- **feat** `packages/tokens` (CSS variables, chart palette, `Tokens.swift`), `packages/db-types`
  (generated), and a pnpm workspace.
- **chore** `supabase/seed.sql` adds synthetic demo ledgers (`demo@ledger.local`).

### iOS

- **feat** `apps/ios`: an XcodeGen project with the Ledger app and the LedgerShare "Add to
  Ledger" PDF extension, an App Group and a shared keychain session.
- **feat** `LedgerKit` holds every decision the app makes:
  - Decimal-exact money and Dubai dates
  - supabase-swift API behind a protocol
  - on-device OTP and debit filtering, `client_msg_id` idempotency
  - App Group outbox with backoff
  - Sentry telemetry and scrubber
  - screen models
- **feat** `LogBankSMSIntent` for the Shortcuts "When I get a message containing…" automation.
  Screens: Overview, Activity, Insights, Statements (upload) and Settings (SMS setup guide,
  outbox status), refreshed by Realtime.
- **chore** `scripts/publish-build.sh`: archive and export, dSYM upload, TestFlight upload.

### Scraper

- **feat** `CCS_SCRAPER_UPLOAD_PATH` (`/functions/v1/statements-upload` for v2) and optional
  `CCS_SCRAPER_SUPABASE_ANON_KEY`. The default target is fixed to `:8040`.
- **feat** Per-file `queued` / `duplicate` status. A failed bank upload no longer aborts the
  others. New `upload-pending` command.

### CI / Infra

- **feat** `ci.yml` gains path-filtered v2 jobs:
  - `supabase`: start, db reset, pgTAP, types drift
  - `edge`: deno test
  - `parser`: uv, ruff, pytest
  - `web`: tokens check, lint, test, build
  - `ios`: `swift test` on LedgerKit, macOS, on LedgerKit/tokens changes or manual runs

  The legacy jobs are kept.
- **feat** Manual-only `deploy-supabase.yml` (db push and/or functions deploy, typed project-ref
  confirmation, `production` environment) and `deploy-parser.yml` (Artifact Registry + Cloud
  Run, min instances 0, Secret Manager).
- **chore** `security.yml` also audits the parser's dependencies. The legacy deploy workflows
  are marked as legacy.

### Docs

- **docs** README, ARCHITECTURE, PRODUCTION and ROADMAP rewritten for v2:
  - structure, prerequisites, local setup, every test command, env vars per component
  - screens, API surface
  - data model, matching and categorisation, auth and RLS, SMS capture
  - Sentry topology (two projects: `ledger-backend`, `ledger-apps`)
  - free-tier deployment
  - cutover runbook with rollback

  CLAUDE.md is rewritten for v2. The legacy `docs/operations` and `docs/security` notes are
  marked as v1.

## [Unreleased]

### Backend

- **feat** Ledger v2 migration `20261008001300_web_followups.sql` — `list_profile_members` (members with auth emails plus pending invites), owner-only `remove_profile_member` (refuses to remove the last owner, 22023) and `cancel_profile_invite`; `preview_rule` now honours `currency` and `card_code` conditions exactly like `private.recategorize` and counts every match (20-row sample); `overview` adds per-account `utilisation` and `change_vs_prev_month_to_date` / `change_vs_avg_3m` fractions (existing keys unchanged); `spend_series` gains optional `p_top` that folds the long tail into an "Other" group (signature change: dropped and recreated). pgTAP suite `06_web_followups.test.sql`; regenerated `packages/db-types`
- **feat** Edge Functions: Sentry tags every event `service=edge` at init (`_shared/sentry.ts`), alongside the per-request `function`, so Edge and parser events separate in the shared `ledger-backend` project; asserted in `sentry_runtime_test.ts`
- **fix** `scripts/migrate_legacy.py --step secrets` writes `GMAIL_OAUTH_CLIENT_ID/SECRET` (was `GOOGLE_OAUTH_CLIENT_*`), exactly the names `_shared/oauth.ts` reads, so the exported env file can be pushed with `supabase secrets set --env-file` without renaming

### Frontend (web)

- **feat** Ledger web: Settings → Members shows emails, roles and pending invites, with confirm dialogs to remove a member or cancel an invite
- **refactor** Ledger web: Overview uses the server's `utilisation` and change fractions (removed `latestCycleByAccount` and `formatDeltaPercent`; `formatChange` only formats a server fraction); Insights → Trends asks the server for the top 8 groups (`p_top`) instead of folding client-side, and keeps grouping/bucket in the URL (`?group=&grain=`), preserved when the range changes
- **chore** `@ledger/tokens` build emits `dist/chart.d.ts` (exported via `types`) and skips unchanged outputs; removed the `apps/web/src/types/tokens.d.ts` stopgap
- **fix** `.gitignore`: the root `data/` rule no longer hides `apps/web/src/data/` (the web data layer)
- **feat** `apps/web/vercel.json`: SPA rewrite to `/index.html` for every path except `/assets/*`, immutable caching for hashed assets, and security headers (`nosniff`, `strict-origin-when-cross-origin`, `X-Frame-Options: DENY`, `Permissions-Policy`, a CSP allowing only self, the inline theme script by hash, the Supabase project over https + wss, and Sentry ingest). Vitest guard `src/test/vercel-config.test.ts` keeps the script hash and CSP in sync with `index.html`
- **feat** Sentry tags every web event `app=web` (`initialScope` in `src/lib/sentry.ts`, tested in `sentry.test.ts`); the source-map upload project defaults to `ledger-apps` (was `ledger-web`) in `vite.config.ts` and `.env.example`
- **fix** `pnpm --filter @ledger/tokens check` works from a clean clone: it regenerates the gitignored `dist/` in memory and fails only when the committed `Tokens.swift` drifts from `tokens.json`

### Parser

- **feat** Sentry tags every parser event `service=parser` at init (`ccs_parser/sentry.py`), sharing `ledger-backend` with the Edge Functions; covered by a pytest case

### iOS

- **feat** LedgerKit `Telemetry` tags every event `app=ios` (plus `target`) via `Telemetry.scopeTags(target:)`, for the shared `ledger-apps` project; dSYM upload in `scripts/publish-build.sh` defaults to `SENTRY_PROJECT=ledger-apps` (was `ledger-ios`)

### Docs

- **docs** PRODUCTION.md: documented `apps/web/vercel.json` (§4) and dropped the "add a vercel.json" note; removed the cutover step to rename `GOOGLE_OAUTH_*` by hand; the scraper cutover step uses per-profile tokens; Sentry tags are no longer "until the runtimes set them". ARCHITECTURE.md §10, README, `scraper/README.md`, iOS README and ROADMAP updated to match

### CI / Infra

- **chore** Pre-commit hook runs `pnpm --filter @ledger/web lint` and `test` when `apps/web/**/*.{ts,tsx}` files are staged (legacy `frontend/` ESLint check unchanged)
- **chore** CI `web` job: the tokens step is just `pnpm --filter @ledger/tokens check` (the build-then-`git diff` workaround is gone)

### Scraper

- **feat** Per-profile service tokens: `get_config(profile)` reads `<PROFILE>_CCS_SCRAPER_API_TOKEN` (profile upper-cased, like the bank credentials) and falls back to the global `CCS_SCRAPER_API_TOKEN`; the fail-fast error names both. Ledger v2 tokens belong to one profile, so `scrape --profile tejasvie` no longer needs the token swapped per run. Updated `.env.example` and README
- **fix** FAB: after "DOWNLOAD STATEMENTS" modal opens, wait for `select[name='estatementTenure']` to become visible before attempting to select months — previously a fixed 700ms wait was insufficient, causing `_download_requested_months` to see `has_tenure=False` and try to re-open the modal (which fails while the modal is already shown), silently skipping all requested months
- **fix** ADCB: wrap `login_selector_visible` and `is_authenticated_session` in try/except to handle `TargetClosedError` — after clicking "Login" on the concurrent-session gate, ADCB navigates/reloads the page and the old page reference closes, causing a crash on the next auth-poll tick
- **fix** SIB: restructure "Secure Login" polling from 3 × 1400ms (4.2s) to 2 × (7 × 1500ms) = up to 21s; click the button once per outer attempt rather than on every inner poll iteration, preventing unintended re-clicks while the password screen is loading

### Backend

- **chore** Build `Dockerfile.api` from the lock files instead of `pip install ".[export]"` — the image previously re-resolved `pyproject.toml`'s version ranges at build time, so production shipped versions that were never tested by CI and never scanned by `pip-audit` (the image had `fastapi` 0.141.1 against a pinned 0.136.3, `sqlalchemy` 2.0.51 against 2.0.47, and so on). The image now installs `requirements.txt` plus a new `requirements-export.txt` in a single pip invocation and adds the project itself with `--no-deps`; verified the built image contains exactly the pinned set and nothing else
- **chore** Add `backend/requirements-export.in` / `requirements-export.txt` — pinned `pandas`/`openpyxl` for the optional `[export]` extra, kept out of `requirements.txt` so the Gmail relay image that shares that lock file does not pull in pandas/numpy; both CI and the Security Scan now run `pip-audit` over it as well
- **chore** Regenerate `backend/requirements.txt` — adds the missing `sentry-sdk[fastapi]==2.66.1` (added to `pyproject.toml` when Sentry monitoring landed but never compiled into the lock file) and `greenlet==3.5.4`; all other pins unchanged
- **chore** Uninstall `pip` from `Dockerfile.api` and `Dockerfile.gmail-relay` after dependencies are installed — pip 26 ships a CycloneDX SBOM of its vendored libraries (`pip/_vendor/bom.cdx.json`) which Trivy reads as installed packages, failing the Security Scan container job on `msgpack` 1.1.2 and `setuptools` 70.3.0 even though nothing in the app imports them; a runtime image needs no package installer, so removing pip clears the findings and trims the attack surface
- **chore** CI: grant the workflow token `pull-requests: read` — `dorny/paths-filter` resolves changed files for `pull_request` events through the PR listFiles API, which failed with "Resource not accessible by integration" under the repo's default token scopes, making the `changes` job (and therefore every downstream job) fail on PRs
- **chore** Bump vulnerable dependencies (pip-audit) — `click` 8.3.1→8.4.2 (PYSEC-2026-2132), `cryptography` 48.0.1→50.0.0 (PYSEC-2026-3552/3553/3554), `pillow` 12.2.0→12.3.0 (PYSEC-2026-2253…2257, 3451…3454, 3493…3496), `pyasn1` 0.6.3→0.6.4 (PYSEC-2026-3455/3456/3457), `pypdf` 6.13.3→6.15.0 (PYSEC-2026-3610…3613, CVE-2026-71852, CVE-2026-71870); lower bounds for the direct dependencies tightened in `pyproject.toml` to prevent re-introduction
- **chore** Bump vulnerable dependencies — `cryptography` 48.0.0→48.0.1 (GHSA-537c-gmf6-5ccf), `pydantic-settings` 2.13.1→2.14.2 (GHSA-4xgf-cpjx-pc3j), `pypdf` 6.13.0→6.13.3 (GHSA-jm82-fx9c-mx94), `starlette` 1.2.1→1.3.1 (PYSEC-2026-248, PYSEC-2026-249); tightened lower bounds in `pyproject.toml` to prevent re-introduction

- **fix** Email ingestion 500 — `save_binary` (GCS upload) was outside the `try/except` block in `POST /email-ingestion/upload`; unhandled exceptions rolled back the DB and returned a generic 500 with no event record; moved `save_binary` inside the block so storage failures produce a FAILED event and a structured error response
- **fix** Email ingestion script: retry on 5xx — `email_ingestion_common.py` now retries HTTP 5xx responses (up to 3 attempts with backoff) instead of raising immediately; 4xx still raises immediately
- **fix** Email ingestion script: per-attachment error isolation — `email_ingest_microsoft.py` now wraps each `api.upload_pdf` call in a try/except; a single failed attachment is counted as `failed` and recorded in `attachment_errors` but no longer aborts the rest of the mailbox; the delta link still advances so future runs do not reprocess messages that already succeeded
- **feat** Sentry error monitoring — `sentry-sdk[fastapi]` added; `init_sentry()` in `ccs_platform/core/sentry.py` wires up FastAPI and SQLAlchemy integrations on startup; controlled via `CCS_PLATFORM_SENTRY_DSN` and `CCS_PLATFORM_SENTRY_TRACES_SAMPLE_RATE` env vars (no-op if DSN is unset)

### Frontend (web)

- **feat** Sentry error monitoring — `@sentry/react` added; initialised in `main.tsx` with browser tracing and session replay (errors only); controlled via `VITE_SENTRY_DSN` and `VITE_ENVIRONMENT` env vars (no-op if DSN is unset)

### Backend

- **chore** Migrate production database from Neon to Supabase — updated PRODUCTION.md setup steps (session pooler DSN, Supabase dashboard instructions), ARCHITECTURE.md provider references, and `.env.example` PostgreSQL DSN example; escape `%` as `%%` in `set_main_option` calls in `session.py` and `alembic/env.py` to fix configparser interpolation error when database password contains percent-encoded characters



- **feat** SIB transaction history PDF support — `parse_sib_transaction_history()` parses SIB's "Transaction history" export (date format `DD MMM YYYY`, amount format `CUR [-]amount`) and splits transactions into per-billing-cycle statements using the 12th of each month as the statement cutoff date (13th of M through 12th of M+1 → statement dated 12th of M+1); duplicate rows across PDF pages are deduplicated by fingerprint; the `parse_statement_for_bank()` dispatcher auto-detects the PDF type for SIB and returns a list when multiple statements are produced; `ingest_statement_pdf()`, the parser adapter, and the upload handler all support 1 PDF → N statements; bank detection in the upload endpoint recognises "TRANSACTION HISTORY" + "ACCOUNT NO." + "ACCOUNT TYPE" as SIB

- **chore** Remove scraper-only runtime settings from seed catalog — `DEFAULT_RUNTIME_SETTING_SPECS` now only includes PDF-password keys used by backend parsers (`FAB_PDF_PASSWORD`, `ADCB_CID`, `ADCB_PDF_PASSWORD`, `ENBD_PDF_PASSWORD`, `SIB_PDF_PASSWORD`); login credentials and scraper-specific flags (`FAB_USERNAME/PASSWORD`, `ADCB_LOGIN_PASSWORD`, `ADCB_FORCE_VIRTUAL_KEYBOARD`, `ENBD_USERNAME/PASSWORD`, `EIB_USERNAME/PASSWORD`, `SIB_USER_ID/PASSWORD/SECURE_IMAGE_TEMPLATE_BASE64`, `MASHREQ_USERNAME/PASSWORD`) are no longer seeded or shown in the UI; migration `20260304_000015` deletes any existing rows for these keys

- **feat** Statement line category override — users can pin a category on any transaction line via `PUT /api/v1/transactions/{id}/category-override`; the pin is stored in a new `category_overrides` table (keyed by fingerprint) and survives both reclassify (skipped by `reclassify_statement_lines`) and reparse (applied during ingestion); `DELETE /api/v1/transactions/{id}/category-override` clears the pin and restores auto-classification; migration `20260304_000014` adds the `category_overrides` table and `category_override` column on `statement_lines`

### Frontend (web)

- **feat** Category override controls — `RawLinesPage` and `StatementsPage` lines tables now show a category dropdown with Pin/Clear buttons; pinned rows display a ⊘ lock indicator; category list is fetched from `GET /api/v1/categories` on mount

### Frontend (web)

- **fix** Proxy API calls through Vercel to fix session cookies on Safari and Chrome incognito — `vercel.json` now rewrites `/api/:path*` to the Render backend so the session cookie is first-party, bypassing browser third-party cookie blocking (`SameSite=None` cross-site cookies were silently dropped)

### Backend

- **feat** Log security events — login success/failure logged via Python logger and audit table; service token creation/revocation emit `service_token_created` / `service_token_revoked` audit events with actor metadata
- **fix** Clean up orphaned staging objects on upload failure — `POST /jobs/upload` now deletes any storage objects already saved before the exception so storage stays consistent with DB state
- **fix** Rate limit login endpoint — sliding window (5 attempts / 60 s per IP) in `POST /auth/login`; returns 429 on excess; no new dependency
- **fix** Add missing FK indexes via migration `20260302_000012` — `job_items.job_id`, `statements.bank_code`, `statement_lines.statement_id`; also declare them in model `__table_args__`
- **fix** Enforce CORS origin list in production — `model_post_init` raises `RuntimeError` if `CCS_PLATFORM_CORS_ALLOW_ORIGINS` is `"*"` or empty when `ENVIRONMENT=production`; `create_app` disables `allow_credentials` when origins is wildcard (browser spec violation)
- **fix** Log bcrypt failures — `authenticate_credentials` now calls `logger.exception()` before returning `None` on bcrypt error; distinguishes corrupted-hash system errors from wrong-password denials
- **fix** Enforce upload size limit — new setting `CCS_PLATFORM_MAX_UPLOAD_SIZE_MB` (default 50); upload endpoint returns 413 for files exceeding the limit
- **feat** Service token expiry — add optional `expires_at` column to `service_api_tokens` (migration `20260302_000011`); `require_service_token` returns 401 if token is past its expiry; `ServiceApiTokenCreate` accepts `expires_at`; `ServiceApiTokenOut` exposes it

### Scraper

- **fix** Fail fast on missing API token — `get_config()` raises `RuntimeError` if `CCS_SCRAPER_API_TOKEN` is unset; previously the error only surfaced at upload time after a full scrape run
- **fix** Retry uploads with exponential backoff — `ScraperClient.upload_pdfs` retries up to 3 times (delays: 5 s, 15 s, 45 s) on transient server errors (5xx / network); 4xx errors are not retried

### Frontend (web)

- **refactor** Split `EmailIngestionPage.tsx` (948 lines) into focused sub-components — `MailboxesPanel`, `OAuthTokenPanel`, `BankRoutingMatrix`, `ServiceTokensPanel`, and a shared `types.ts`; main page is now ~230 lines
- **feat** Add `extractErrorMessage` utility — consistent error message extraction from `Error` objects, FastAPI JSON bodies (`{"detail":"…"}`), and strings; available in `lib/errors.ts`
- **feat** Add `ConfirmDialog` component — modal confirmation before destructive actions; used on service token revocation
- **fix** Add `ErrorBoundary` component wrapping the entire app — catches React render errors and shows a "Something went wrong" fallback with a reload button instead of a blank screen

### CI / Infra

- **feat** Add scraper test job to CI pipeline — runs `pytest` on `scraper/**` changes; no browser required (tests mock httpx)
- **fix** Expose `scraper` change-detection output in CI `changes` job — was declared in path filters but not wired to outputs
- **chore** Pin backend dependencies via `pip-compile` — `requirements.txt` now contains fully-pinned transitive versions generated from `requirements.in` / `pyproject.toml`

### Docs

- **docs** Update `ARCHITECTURE.md` — document in-process rate limiter, token expiry/audit, error boundary, and confirm dialog
- **fix** Restore `deploy/nginx/frontend.conf` — standard SPA nginx config (try_files, aggressive cache headers for hashed assets, no-cache for index.html); `Dockerfile.frontend` was broken without it
- **fix** Fix `security.yml` Trivy scan job — update Dockerfile reference from deleted `Dockerfile.app` to `Dockerfile.api`; CI security job was always failing
- **chore** Add non-root `appuser` (uid 1000) to `Dockerfile.api` and `Dockerfile.gmail-relay`; switch `Dockerfile.frontend` to built-in `nginx` user with corrected directory ownership

- **docs** Add Microsoft Outlook / Hotmail ingestion section to `PRODUCTION.md` (section 6) — Azure app registration, API permissions (`Mail.Read`, `offline_access`), client secret, Render env vars (`CCS_PLATFORM_EMAIL_INGESTION_ENABLED`, `CCS_PLATFORM_EMAIL_MS_CLIENT_ID`, `CCS_PLATFORM_EMAIL_MS_CLIENT_SECRET`), OAuth refresh token generation via admin UI, mailbox setup, and verification steps; renumber Scraper CLI section from 6 to 7
- **docs** Remove pre-deploy command from `PRODUCTION.md` — `init_db()` already runs `alembic upgrade head` automatically on startup for PostgreSQL; pre-deploy command is a paid Render feature and is not needed

### Backend

- **fix** Email ingestion `_runtime_setting_value` now falls back to Pydantic settings (`CCS_PLATFORM_EMAIL_MS_CLIENT_ID`, `CCS_PLATFORM_EMAIL_MS_CLIENT_SECRET`, etc.) when the DB row is missing — eliminates the need to duplicate OAuth client credentials as runtime settings when they are already set as env vars on the server

- **fix** MASHREQ parser: parse credit transactions whose amount ends with a trailing ` -` suffix — extend both `_ROW_RE_SHORT` and `_ROW_RE` suffix group to `(?:CR|DR|-)` and treat `-` suffix same as `CR` (negate the amount); credits appearing after the debits sub-total (e.g. inward IPP payments) were previously silently skipped

- **feat** Make service tokens profile-agnostic — drop `profile_id` FK from `service_api_tokens` (migration `20260301_000010`); add global `UNIQUE(name)` constraint; `ServiceTokenContext` no longer carries `profile_id`/`profile_key`; `get_profile_context_or_service_token` now requires `X-Profile-Key` header when using a bearer token; automation entity endpoints (`/oauth/{provider}/access-token`, `PATCH /mailboxes/{mailbox_id}/sync-state`, `POST /upload`) auto-derive profile from the mailbox/route in the request; automation list endpoints (`GET /automation/mailboxes`, `GET /automation/routes`) return data across all profiles; token management endpoints (list, create, revoke) are global and no longer scoped to the active profile

- **fix** Lazy-import `pandas` inside `build_yearly_workbook_from_statements()` — removes ~104 MB (pandas + numpy) from startup memory footprint, fixing OOM crash (exit code 3) on Render 512 MB free tier
- **fix** Lazy-import `pdfplumber` inside `_extract_pdf_text()` in `jobs.py` — consistent with lazy-import pattern; was already loaded transitively via bank parsers but removes the module-level import
- **fix** Lazy-import all bank parsers in `dispatcher.py` and `parser_validate.py` — removes pdfplumber (~15 MB) from startup; parsers are now imported only when a parse job actually runs; cleaned up `parsers/__init__.py` to stop eagerly re-exporting all 6 parsers
- **fix** Add `pool_size=2`, `max_overflow=2`, `pool_recycle=300` for PostgreSQL engine — prevents "SSL connection closed" errors caused by Render managed Postgres dropping idle connections after 5 min; keeps total connections within free tier's 25-connection limit
- **chore** Add `CCS_PLATFORM_REQUEST_LOGGING_ENABLED=false` to Render env vars in `PRODUCTION.md` and document the setting in `backend/.env.example`
- **refactor** Delete `adapters/banks/browser/` — dead browser adapter code (base, downloader, shared, and 6 bank adapters) removed from backend; confirmed zero imports outside that directory after decoupling
- **refactor** Rename package `creditcardstatementscraper` → `ccs-platform` in `pyproject.toml`; remove `playwright>=1.50` dependency
- **fix** Change `ScheduleCreate.job_type` default from `JobType.SCRAPE` to `JobType.UPLOAD` — SCRAPE has no handler and raises `ValueError` at runtime
- **chore** Add deprecation comments to `JobType.SCRAPE` and `JobType.BANK_CONNECTION_TEST` in `enums.py` — no handlers exist; kept in enum for PostgreSQL compatibility only
- **chore** Rewrite `backend/.env.example` — remove browser geo-spoofing section (`BROWSER_PROXY_URL`, `BROWSER_GEO_*`, `BROWSER_TIMEZONE_ID`, `BROWSER_LOCALE`); remove `QUEUE_BACKLOG_SLO_SCRAPE`; update `WORKER_QUEUES` default to `default`; rename "Scraper credentials" section to "Bank credentials (seeded into runtime settings)"; fix timezone comment ("scrape-month" → "billing month")

### Scraper

- **feat** Introduce `BankMap` — persistent JSON map (`state/bank_map.json`) that records each downloaded PDF's origin bank at download time; `scrape` command creates the map before scraping, passes it to `run_end_to_end_downloads`, then groups new PDFs by their recorded bank code and uploads each group with an explicit `bank_code` arg; entries are removed after a successful upload; PDFs not in the map (e.g. pre-existing files or manual downloads) fall through to the existing backend detection logic — eliminates all ambiguity in PDF→bank mapping at upload time
- **feat** Pass `bank_code_hint` from scraper to backend on `/api/v1/jobs/upload` — when the scraper knows the bank (via `BankMap` or filename prefix), it sends `bank_code_hint` as a multipart form field so the backend skips the expensive `pdfplumber` content scan entirely

- **refactor** Make bank adapter system generic and auto-discovering — add `AuthPollAction` enum and `AuthPollState` dataclass to `base.py`; expand `BankAdapter` with optional hook params (`is_authenticated_session`, `is_login_screen`, `is_login_failure`, `on_auth_poll_tick`, `skip_mfa_user_prompt`, `skip_keyword_fallback`, `skip_login_selector_fallback`, `browser_launch_overrides`); add `discover_adapters()` via `pkgutil` auto-discovery; move all bank-specific auth logic (FAB continue gate, ADCB OTP/concurrent session/re-login, MASHREQ anti-bot retry) into per-adapter `on_auth_poll_tick` hooks; replace ~135 lines of `if code ==` branching in `downloader.py` with a generic hook-based polling loop; `_launch_bank_context` now reads `channel_candidates` and `init_scripts` from `adapter.browser_launch_overrides()`; adding a new bank now requires only a new adapter module with an `ADAPTER` constant — no changes to `downloader.py`
- **docs** Add `scraper/ADDING_A_NEW_BANK.md` — step-by-step guide covering the 3 required functions, all optional hook functions with examples, `AuthPollAction`/`AuthPollState` field references, and verification commands

- **refactor** Make `--profile` a required option on `scrape` and `upload` CLI commands — remove `CCS_SCRAPER_PROFILE_KEY` env var support; `get_config(profile: str)` now requires a profile; `ScraperConfig.profile_key` defaults to `""` instead of reading from env

### Scraper

- **chore** Add `scraper/.env.example` — documents all `CCS_SCRAPER_*` settings and bank credential keys with inline comments
- **test** Add scraper test suite (`tests/`): `test_config.py` (env var parsing, profile isolation, credential filtering), `test_month_utils.py` (month name/abbreviation mapping), `test_bank_config.py` (YAML loading, path structure), `test_shared.py` (MFA/failure pattern detection, PDF snapshot utilities, `require_env`), `test_client.py` (HTTP upload request structure, headers, multipart); no browser automation required — 86 tests, all pure logic
- **chore** Add `[project.optional-dependencies] dev = ["pytest>=8.0"]` and pytest config (`testpaths`, `pythonpath`) to `scraper/pyproject.toml`; fix build backend to `setuptools.build_meta`
- **chore** Add scraper test step to `scripts/hooks/pre-commit` — runs `pytest -q` via `scraper/.venv/bin/pytest` when scraper files are staged; skips gracefully if scraper venv not found; update `scraper/README.md` to show `pip install -e ".[dev]"`

### Docs

- **docs** Create `backend/README.md` — setup, database, run commands, test instructions, key env vars, password hash generation
- **docs** Update `scraper/README.md` — expand setup section with explanation of `pip install -e .`, add `cp .env.example .env` step
- **docs** Update root `README.md` — reference `backend/README.md` in backend setup section; reference scraper `.env.example`

### Backend

- **refactor** Remove browser scraping from backend: delete `handlers/scrape.py`, `handlers/bank_connection_test.py`, `adapters/banks/browser/` (browser code moved to `scraper/`); remove `POST /jobs/scrape` and `POST /diagnostics/bank-connection-test` endpoints; remove `ScrapeJobRequest` schema; remove `SCRAPE` and `BANK_CONNECTION_TEST` from job dispatcher and service defaults; remove `browser_proxy_url`, `browser_geo_*`, `browser_timezone_id`, `browser_locale`, `queue_backlog_slo_scrape` from settings; change `worker_queues` default to `default`; remove `playwright>=1.50` from `requirements.txt`
- **feat** Add `require_operator_or_service_token` and `get_profile_context_or_service_token` dependencies in `api/deps.py`; `POST /jobs/upload` now accepts either a session (operator+) or a Bearer service token with `upload` scope — enables the scraper CLI to upload directly

### Scraper

- **feat** Add `scraper/` — standalone Python CLI package for browser-based bank statement downloads; Playwright + Chromium bank adapters (FAB, ADCB, ENBD, EIB, SIB, Mashreq) moved verbatim from backend with updated import paths; `ccs-scraper scrape` downloads PDFs and uploads to backend; `ccs-scraper upload` sends local PDFs; `ccs-scraper install-browser` installs Chromium; all config via `CCS_SCRAPER_*` env vars

### DevOps

- **chore** Delete `deploy/Dockerfile.app` (Playwright image no longer needed); update `Dockerfile.api` comment; simplify `docker-compose.prod.yml` — remove `worker` service and `edge_public` on `app_internal` containers; API service gets `CCS_PLATFORM_EMBEDDED_WORKER=true` and `edge_public` for outbound GCS/email connectivity
- **ci** Remove `deploy/Dockerfile.app` from backend path filter in `ci.yml`; add `scraper/**` filter; update `deploy-backend.yml` to remove `Dockerfile.app` from change detection pattern

### Docs

- **docs** Create `ARCHITECTURE.md` — system overview, component boundaries, data flows, auth model, technology stack, design decisions
- **docs** Rewrite `PRODUCTION.md` — single deployment plan covering Render (API), Vercel (frontend), Neon (PostgreSQL), GCS (storage), Cloud Run (Gmail relay), and local Scraper CLI; remove Plan 2 (GCP full), standalone worker, and all browser-related env vars
- **docs** Update `README.md` — add `scraper/` to directory structure, describe decoupled architecture, add Scraper CLI quick-start, remove Dockerfile.app and worker service references

### Backend

- **feat** Add `job_logs` table and `JobDBLogHandler` — captures all `ccs_platform.*` and `playwright.*` INFO+ log records emitted during a job run into `job_logs` via thread-local job ID; retention cleans up entries older than 7 days (`retention_job_logs_days=7`); `GET /jobs/{id}/logs` endpoint returns the log stream; alembic migration `20260301_000009`
- **feat** Add `JobLogOut` response schema; `GET /jobs/{job_id}/logs` endpoint (limit up to 2000)
- **feat** Statements list: rename "Date" column to "Statement Date"; add "Upload Date" column showing `ingested_at` (already in DB/API, no migration needed)
- **feat** Add `deploy-gmail-relay.yml` GitHub Actions workflow — automatically rebuilds and redeploys the `ccs-gmail-relay` Cloud Run service on changes to `gmail_ingest_relay.py`, `email_ingestion_common.py`, `requirements.txt`, or `deploy/Dockerfile.api`; uses `GCP_SA_KEY`, `GCP_PROJECT_ID`, `CCS_API_BASE_URL`, and `CCS_GMAIL_RELAY_SERVICE_TOKEN` secrets
- **fix** Eliminate temp-dir cross-process dependency in the upload pipeline: PDF uploads (manual UI and email ingestion) are now saved directly to the storage backend (GCS in prod, local `StorageAdapter` in dev) and a `storage_key` is stored in the job payload instead of a local file path; the upload job handler reads from storage and deletes the staging object after processing; backward-compatible with queued jobs that still carry `temp_path`; export workbook handler now writes to `io.BytesIO` instead of a temp file; `build_yearly_workbook_from_statements` accepts `Path | BinaryIO`; `delete(key)` added to all storage adapters (`StorageAdapter` base, `GCSStorageAdapter`, `LocalStorageAdapter`)
- **fix** Use `/consumers/` endpoint for Microsoft token refresh in `TOKEN_ENDPOINT_BY_PROVIDER`; was incorrectly using `/common/`, causing `AADSTS9002331` errors for personal-account-only app registrations
- **fix** Use `mailFolders/Inbox/messages/delta` instead of `messages/delta` in `email_ingest_microsoft.py`; Graph API does not support change tracking on the top-level messages collection, only on specific folders
- **feat** Scan `Inbox`, `DeletedItems`, and `Archive` folders per mailbox in `email_ingest_microsoft.py`; each folder tracks its own delta link in sync_state (`microsoft_delta_link_inbox`, `microsoft_delta_link_deleteditems`, `microsoft_delta_link_archive`); missing folders (e.g. no Archive) are silently skipped (HTTP 404); backwards-compatible with old single `microsoft_delta_link` key
- **fix** Handle permanently-deleted Gmail messages in `gmail_ingest_relay.py`; `get_message` 404 (message hard-deleted before relay processed the push) now skips silently instead of crashing the notification handler
- **feat** Add four optional env-var-backed settings fields (`email_ms_client_id`, `email_ms_client_secret`, `email_gmail_client_id`, `email_gmail_client_secret`) to `PlatformSettings`; sourced from `CCS_PLATFORM_EMAIL_MS_*` / `CCS_PLATFORM_EMAIL_GMAIL_*` env vars; profile-agnostic, no DB table
- **feat** Add `OAuthConfigOut`, `OAuthCodeExchangeRequest`, `OAuthCodeExchangeOut` schemas to `email_ingestion.py`
- **feat** Add `GET /api/v1/email-ingestion/oauth/config` — returns auth URLs and `configured` status for Microsoft and Gmail; auth URLs built from the new settings fields
- **feat** Add `POST /api/v1/email-ingestion/oauth/exchange-code` — exchanges an OAuth authorisation code for a refresh token entirely server-side; reads client credentials from settings; returns `OAuthCodeExchangeOut`; never persists the token

### Frontend (web)

- **feat** Remove `profile_id` from `ServiceApiTokenOut` type in `EmailIngestionPage.tsx` — tokens are now global; field no longer returned by the API

- **feat** Add **OAuth Token Setup** panel to `EmailIngestionPage.tsx` between Mailboxes and Bank Routing Matrix; one card per provider with Authorize link, code input, server-side exchange, token copy button, mailbox dropdown, and Save to Mailbox action; code input accepts raw code or full redirect URL

### Docs

- **docs** Update `PRODUCTION.md` EI-4: replace multi-step manual curl workflow with new in-UI OAuth flow (6 steps, no terminal)
- **docs** Update `backend/.env.example`: document the four `CCS_PLATFORM_EMAIL_*` OAuth credential env vars

- **refactor** Comprehensive env-var config redesign: `session.py` engine/SessionLocal creation is now lazy (`@lru_cache` `get_engine()`/`get_session_local()`); `auth/service.py` `_ACCOUNTS` replaced with lazy `_build_accounts()`; login hashes moved from raw `os.getenv()` to pydantic-settings fields (`login_hash_hussain`, `login_hash_tejasvie`); `_SUPPRESS_ENV_FILE` hack replaced with `PYTEST_CURRENT_TEST` detection in `_resolve_env_file()`; `load_dotenv()` bridge removed; `clear_settings_caches()` centralises cache-clearing for tests; `conftest.py` simplified to a clean autouse fixture
- **fix** `get_settings()` now calls `load_dotenv()` alongside pydantic-settings so that values in `backend/.env` (e.g. `CCS_PLATFORM_LOGIN_HASH_*`) are visible to `os.getenv()` calls made at module-import time (fixes HTTP 401 on local backend when hashes are set only in `.env`)
- **fix** `conftest.py` sets `_SUPPRESS_ENV_FILE=True` before importing `ccs_platform.db` so the real encryption key is never loaded into `os.environ` during pytest — encryption-related tests that use `monkeypatch` work correctly again
- **security** Remove hardcoded fallback password in `auth/service.py`; raise `RuntimeError` at startup if a login credential env var is absent in production (ROADMAP 1.1)
- **security** Add `session.rollback()` on exception in `get_db` FastAPI dependency so partial writes are never committed on error (ROADMAP 1.2)
- **security** Validate `CCS_PLATFORM_SESSION_SECRET_KEY` at startup in production — raises `RuntimeError` if the value is the insecure default or shorter than 32 bytes (ROADMAP 1.3)
- **security** Eliminate thread-unsafe `os.environ` mutation for bank credential injection; credentials are now fetched as a plain dict and passed explicitly through the adapter call chain so concurrent worker threads cannot corrupt each other's credentials (ROADMAP 1.4)
- **security** Upload endpoint (`POST /jobs/upload`) now loads ADCB PDF passwords from the `runtime_settings` table instead of `os.environ`, so credentials updated via the admin UI are reflected without a restart (ROADMAP 1.5)
- **architecture** Extract `JobRunner` God-class (1,068 lines) into `application/jobs/handlers/` package — one module per job type (`upload`, `scrape`, `reclassify`, `export_workbook`, `parser_validate`, `bank_connection_test`, `reparse`); `JobContext` dataclass decouples handlers from the runner; `runner.py` reduced to 237-line thin dispatcher (ROADMAP 2.1)
- **architecture** Introduce repository layer (`StatementRepository`, `JobRepository`, `CategoryRepository`) in `db/repositories/`; all SELECT/COUNT query logic moved out of route handlers (ROADMAP 2.2)
- **architecture** Add `BankAdapter` dataclass and `LoginFn` / `LoginSelectorVisibleFn` / `DownloadLatestStatementFn` Protocol types in `adapters/banks/browser/base.py`; `downloader.py` now registers all adapters in a single `BANK_ADAPTERS` dict instead of three separate Callable maps (ROADMAP 2.3)
- **architecture** Consolidate `MONTH_INDEX` into `domain/parsing/month_utils.py`; all five bank adapters import from the single source of truth (ROADMAP 2.4)
- **architecture** Replace bespoke RRULE parser with `dateutil.rrule.rrulestr` in `application/jobs/scheduler.py`; DAILY, MONTHLY, and YEARLY schedules now work correctly (ROADMAP 2.5)
- **testing** Add `backend/tests/conftest.py` with shared `sqlite_engine`, `db_session`, `sample_profile`, `sample_banks`, and `dev_settings` fixtures; eliminates per-file boilerplate (ROADMAP 3.6)
- **fix** Correct `ROOT_DIR` resolution in `core/bank_config.py` (`parents[2]` → points to `backend/`) so `config/banks.yaml` is found when running from the project root with `PYTHONPATH=backend`
- **refactor** Remove hardcoded `"hussain"` profile key fallback from `deps.py`; default now falls through to `get_default_profile(db)`; `ProfileContext` enriched with `is_default` field; `runtime_settings.py` guard uses `not profile.is_default` (ROADMAP 3.2)
- **refactor** Drop dead `CategoryRule` columns `priority`, `bank_code`, `card_last4` from model and all callers; Alembic migration `20260228_000007` removes the columns and `ix_category_rules_priority` index (ROADMAP 3.3)
- **refactor** Move `EXPECTED_SAMPLE_COUNTS` out of `parser_validate.py` into `domain/parsing/bank_samples.py` as `PARSER_SAMPLE_EXPECTED_COUNTS` (ROADMAP 3.4)
- **refactor** Add `backend/requirements.in` as pip-tools source-of-truth; `requirements-dev.txt` gains `pip-tools>=7.0`; run `pip-compile requirements.in` to regenerate the lock file (ROADMAP 3.5)
- **perf** Fix N+1 query in `reclassify_statement_lines`: active rules fetched once via `_fetch_active_rules(db)`; per-line matching done by pure `find_best_rule(rules, merchant)` function; dead `bank_code`/`card_last4` params removed from `categorize()` (ROADMAP 3.8)
- **fix** Log heartbeat thread errors in `runner.py` via `_log.exception()` before exiting; `_run_job` unhandled exceptions also logged; jobs now surface failures rather than silently hanging (ROADMAP 3.1 / 3.9)
- **feat** Run `alembic upgrade head` automatically at startup for non-SQLite (PostgreSQL) databases; removes need for any manual migration step or paid Render feature in production (`db/session.py` `init_db()`)
- **fix** `test_email_ingestion_api.py` tests now use an isolated per-test temp SQLite file instead of the default `platform.db`; prevents test mailboxes, tokens, and routes from leaking into the development database; deleted 64 leaked test mailboxes and related rows from `platform.db`
- **fix** `test_platform_api.py` CI failures: add `_test_platform_env` autouse fixture that sets a per-test temp SQLite DB, a precomputed bcrypt hash, and explicitly calls `init_db()` + `seed_defaults()` before the test body; all 28 tests now pass without any secrets configured in CI

### Frontend (web)

- **feat** Move Ingestion Activity out of Email Ingestion config page into its own dedicated page (`/email-ingestion/activity`) under the Operations nav section — prevents the event log from crowding configuration panels as it grows over time
- **docs** Rewrite `PRODUCTION.md` email ingestion section: full step-by-step setup guide for Azure OAuth app registration, GCP OAuth client setup, mailbox creation, refresh token flow, bank routing matrix field reference, service token creation; clarify that all OAuth credentials live in Runtime Settings (not deployment env vars); add test-data cleanup note and routing troubleshooting table

- **testing** Configure Vitest 3 + `@testing-library/react` + `jsdom` as the frontend test framework; add `npm test` and `npm run test:watch` scripts (ROADMAP 4.1)
- **testing** Extract duplicated inline utilities to `src/lib/`: `format.ts` (`formatAmount`), `errors.ts` (`isAbortError`), `useDebounce.ts` (`useDebouncedValue`); update imports in `DashboardPage`, `RawLinesPage`, `RuntimeSettingsPage` (ROADMAP 4.1 / 4.3 partial)
- **testing** Add 25 unit tests across 4 test files: `format.test.ts`, `errors.test.ts`, `useDebounce.test.ts`, `datetime.test.ts`
- **security** Remove hardcoded personal email `h_abbasi97@hotmail.com` from `LoginPage.tsx`; email field starts empty (ROADMAP 4.5)
- **fix** Add `2000` to `PAGE_SIZE_OPTIONS` in `TablePagination.tsx`; options are now `[100, 200, 500, 1000, 2000]` per CLAUDE.md rule 12 (ROADMAP 4.6)
- **refactor** Deduplicate `LoginResponse` type: defined once in `src/types/auth.ts`, imported by `App.tsx` and `LoginPage.tsx` (ROADMAP 4.7)
- **feat** `ExportsDiagnosticsPage` now fetches bank list from `GET /api/v1/banks` on mount instead of hardcoding bank codes; shows loading state; auto-selects first bank (ROADMAP 4.8)
- **refactor** Extract all data-fetching logic from `DashboardPage` into `src/lib/useDashboardData.ts` hook; `DashboardPage` reduced from 408 to ~195 lines (ROADMAP 4.9)
- **types** Eliminate all `any` typings across the frontend: new types in `src/types/statements.ts` (`Statement`, `StatementLine`, `PagedResponse`, `Schedule`, `Job`, `Bank`, `Category`, `CategoryRule`, `RuleTestResult`, `RawLine`) cover all API response shapes (ROADMAP 4.4)
- **tooling** Add ESLint 9 (flat config), `@typescript-eslint/eslint-plugin`, `eslint-plugin-react-hooks`, `prettier`, `eslint-config-prettier`; `eslint.config.js` and `.prettierrc` configured; `npm run lint` and `npm run format` scripts added; lint passes with `--max-warnings 0` (ROADMAP 4.2)

### DevOps

- **infra** Add `deploy/Dockerfile.api` — slim image with no Playwright (~500 MB smaller); docker-compose `api` service now builds from it; `Dockerfile.app` (with Playwright) retained for the `worker` service and Render embedded-worker deployments (ROADMAP 5.1)
- **fix** Add `edge_public` network to the `worker` service in `docker-compose.prod.yml` so browser scraping can reach bank websites; all other internal services remain on `app_internal` (ROADMAP 5.2)
- **chore** Remove dead `deploy/nginx/` directory; Caddy is the only reverse proxy in use (ROADMAP 5.5)
- **docs** Update PRODUCTION.md GCP section: build and push `$IMAGE_API` (Dockerfile.api) and `$IMAGE_WORKER` (Dockerfile.app) separately; deploy API and migration job from `$IMAGE_API`, worker from `$IMAGE_WORKER`

### Docs

- **ci** Add `Run frontend tests` step to `frontend-gates` job in `release-cicd.yml`; runs `npm test -- --run` before the build on every PR and push (ROADMAP 5.3)
- **docs** Expand PRODUCTION.md Plan 1 (Free) from a stub into a full step-by-step guide covering secret generation, Neon DB setup, Render Web Service and Background Worker configuration (env vars, persistent disk, queue split), Alembic migration strategy (pre-deploy command), credential seeding via admin UI, Vercel frontend deploy, CORS wiring, health-check verification, and ongoing operations (log access, storage upgrade, key rotation)
