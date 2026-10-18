# Bank Ledger: lessons learned

> Read the index at session start. Add an entry after any correction from the user, or after
> a bug that cost a debugging session (CLAUDE.md §12.3). Newest first. The title is the lesson,
> so the index alone should tell you whether an entry applies to what you are about to do.
> When a lesson can be checked by a machine, add the guard and name it under **Enforced by**.

## Index

| When | Lesson |
|---|---|
| 2026-10-18 | [An automation can't feed an App Shortcut: capture intents are actions only](#an-automation-cant-feed-an-app-shortcut-capture-intents-are-actions-only) |
| 2026-10-16 | [A background intent's parameters are optional: an empty required one makes iOS ask, and nobody answers](#a-background-intents-parameters-are-optional-an-empty-required-one-makes-ios-ask-and-nobody-answers) |
| 2026-10-14 | [`invalid_client` is the app's secret, not the mailbox: rotate it, don't reconnect](#invalid_client-is-the-apps-secret-not-the-mailbox-rotate-it-dont-reconnect) |
| 2026-10-14 | [A typed `NavigationStack` path drops every other value: push only its route type](#a-typed-navigationstack-path-drops-every-other-value-push-only-its-route-type) |
| 2026-10-14 | [TanStack Router lays validated search over the raw URL: a dropped key survives](#tanstack-router-lays-validated-search-over-the-raw-url-a-dropped-key-survives) |
| 2026-10-13 | [Build `supabase.rpc` arguments as a typed variable: a spread union hangs `tsc`](#build-supabaserpc-arguments-as-a-typed-variable-a-spread-union-hangs-tsc) |
| 2026-10-12 | [Check what production serves, not what Vercel says it shipped](#check-what-production-serves-not-what-vercel-says-it-shipped) |
| 2026-10-12 | [Git hooks export `GIT_DIR`: in a worktree, every child git uses the wrong repository](#git-hooks-export-git_dir-in-a-worktree-every-child-git-uses-the-wrong-repository) |
| 2026-10-12 | [Beta App Review must be able to sign in: keep a demo account](#beta-app-review-must-be-able-to-sign-in-keep-a-demo-account) |
| 2026-10-12 | [A bank logo is the bank's own file, downloaded, never drawn](#a-bank-logo-is-the-banks-own-file-downloaded-never-drawn) |
| 2026-10-12 | [A recursive search reads every file under its root, secret files included](#a-recursive-search-reads-every-file-under-its-root-secret-files-included) |
| 2026-10-12 | [Closing a review is not fixing the data: a total counts what the review was about](#closing-a-review-is-not-fixing-the-data-a-total-counts-what-the-review-was-about) |
| 2026-10-11 | [A row's identity hash names its parent: moving the row means re-keying it](#a-rows-identity-hash-names-its-parent-moving-the-row-means-re-keying-it) |
| 2026-10-11 | [Only a purchase line's two amounts are a conversion rate](#only-a-purchase-lines-two-amounts-are-a-conversion-rate) |
| 2026-10-11 | [An FX estimate uses the card's own bank, never another bank's rate](#an-fx-estimate-uses-the-cards-own-bank-never-another-banks-rate) |
| 2026-10-09 | [A filter on the phone loses data for good: send it, classify on the server](#a-filter-on-the-phone-loses-data-for-good-send-it-classify-on-the-server) |
| 2026-10-09 | [Golden parity is local-only: a worktree (and CI) skip it](#golden-parity-is-local-only-a-worktree-and-ci-skip-it) |
| 2026-10-08 | [`supabase config push` has no dry run and pushes the whole file](#supabase-config-push-has-no-dry-run-and-pushes-the-whole-file) |
| 2026-10-08 | [A push to `main` is a production deploy](#a-push-to-main-is-a-production-deploy) |
| 2026-10-08 | [Stage explicit paths; `git add -A` commits other people's work](#stage-explicit-paths-git-add--a-commits-other-peoples-work) |
| 2026-10-08 | [A secret that reached a transcript is a secret to rotate](#a-secret-that-reached-a-transcript-is-a-secret-to-rotate) |
| 2026-10-08 | [Clients hold the publishable key; only Edge Functions hold the secret key](#clients-hold-the-publishable-key-only-edge-functions-hold-the-secret-key) |
| 2026-10-08 | [Never push an env file "as is"](#never-push-an-env-file-as-is) |
| 2026-10-08 | [Never `REVOKE EXECUTE`: on PG 17.6.1.104 the call segfaults the server](#never-revoke-execute-on-pg-1761104-the-call-segfaults-the-server) |
| 2026-10-08 | [Policies read `= any ((select f())::text[])`, and both halves matter](#policies-read--any-select-ftext-and-both-halves-matter) |
| 2026-10-08 | [Local green is not prod green: prod has older default privileges](#local-green-is-not-prod-green-prod-has-older-default-privileges) |
| 2026-10-08 | [`migration up` matches versions, not contents: reset before pgTAP](#migration-up-matches-versions-not-contents-reset-before-pgtap) |
| 2026-10-08 | [The `legacy` schema and the leftover `backend/` folder are kept](#the-legacy-schema-and-the-leftover-backend-folder-are-kept) |
| 2026-10-08 | [A broad `.gitignore` rule hides source: check new paths with `git check-ignore`](#a-broad-gitignore-rule-hides-source-check-new-paths-with-git-check-ignore) |
| 2026-10-08 | [Sentry is off in local, dev and test; the real projects are `credit-card-ledger-*`](#sentry-is-off-in-local-dev-and-test-the-real-projects-are-credit-card-ledger-) |
| 2026-10-08 | [App Store processing rejects "iPhone" in App Intent text (ITMS-90626)](#app-store-processing-rejects-iphone-in-app-intent-text-itms-90626) |
| 2026-10-08 | [Green tests are not a working feature: run it and look at it](#green-tests-are-not-a-working-feature-run-it-and-look-at-it) |
| 2026-10-08 | [Tooling defaults that don't work here: `gh` account, Supabase MCP, `localhost`, pip](#tooling-defaults-that-dont-work-here-gh-account-supabase-mcp-localhost-pip) |

## Lessons

### An automation can't feed an App Shortcut: capture intents are actions only
- **What went wrong**: on iOS 26 a Transaction automation's "Do" picker offered the
  "Log Card Payment" App Shortcut tile (from `LedgerShortcuts`). Picked, it runs with the
  parameters fixed in the `AppShortcutsProvider` (none) and shows no fields, so Amount, Merchant
  and Card could not be bound to Shortcut Input and every payment was refused as missing a
  merchant. iOS 27's editor showed the fields, which hid the problem there.
- **Rule**: an intent whose parameters come from Shortcut Input is an action only
  (`isDiscoverable = true`), never an `AppShortcut`; guides say which action text to tap.
- **Enforced by**: LedgerKit `BackgroundIntentParameterGuardTests` (`notAppShortcuts`).

### A background intent's parameters are optional: an empty required one makes iOS ask, and nobody answers
- **What went wrong**: build 32 hit a fatal app hang 4 s after launch (Sentry 7796165023) with an
  `LNNeedsValueRequest` being sent from the App Intents runtime: a non-optional `@Parameter`
  ("Log Bank SMS" Message, "Log Card Payment" Merchant/Card) arrived empty from an automation,
  so iOS asked for a value instead of running `perform()`, while LedgerKit already had the
  empty-input answers (`dropEmpty`, `missingMerchant`, `missingCard`) that never got the chance.
- **Rule**: every parameter of an `openAppWhenRun = false` intent run by automations is optional;
  pass `?? ""` and let LedgerKit refuse empty input. A `requestValueDialog` belongs only on
  intents a person runs by hand.
- **Enforced by**: LedgerKit `BackgroundIntentParameterGuardTests`.

### `invalid_client` is the app's secret, not the mailbox: rotate it, don't reconnect
- **What went wrong**: on 2026-10-14 `outlook-poll` went from a clean 06:05 UTC run to
  `HTTP 401 invalid_client` at 07:05, with no deploy in between. Microsoft answers
  `invalid_client` when the Azure app's own credentials fail (expired secret AADSTS7000222,
  wrong value AADSTS7000215, deleted app), so reconnecting the mailbox cannot fix it. The error
  carried only the `error` field, which can't tell those cases apart.
- **Rule**: `TOKEN_REFRESH_FAILED:invalid_client` means rotate `MS_OAUTH_CLIENT_SECRET`
  (PRODUCTION.md §6.5) and record the new expiry there; `invalid_grant` is the one that means
  re-authorise the mailbox. Token-refresh errors carry the provider's codes, never
  `error_description`.
- **Enforced by**: `supabase/functions/_tests/outlook_poll_test.ts` (the AADSTS code reaches the
  error; `error_description` never does).

### A typed `NavigationStack` path drops every other value: push only its route type
- **What went wrong**: N-4 (build 29) gave Settings `NavigationStack(path: [SettingsRoute])` so a
  deep link could push Statements. Statements' rows were `NavigationLink(value: cycle)`, a
  `StatementCycle`, which a `[SettingsRoute]` path cannot hold: the tap did nothing, with no error,
  for two releases. Found only by tapping it in the simulator during batch 8 QA.
- **Rule**: inside a stack with a typed path, every `NavigationLink(value:)` and
  `.navigationDestination(for:)` uses that route type (`SettingsRoute.statement(cycle)`). Typing a
  path is a change to every screen that stack can reach.
- **Enforced by**: LedgerKit `SettingsPathGuardTests` (scans `Ledger/Settings` and `Ledger/Statements`).

### TanStack Router lays validated search over the raw URL: a dropped key survives
- **What went wrong**: batch 8 dropped `pending` from the Activity status codec, but
  `/activity?status=pending` still filtered: the root route has no `validateSearch`, passes the
  raw search through, and a child's validated search is merged over it, so a key the child omits
  keeps its raw value.
- **Rule**: a `validateSearch` that may drop a key returns it explicitly as `undefined`
  (`activityRouteSearch`). Check a codec change by loading the old URL in the browser, not only
  with the codec's unit test.
- **Enforced by**: `activity-filters.test.ts` ("the route search overrides a dropped raw key").

### Build `supabase.rpc` arguments as a typed variable: a spread union hangs `tsc`
- **What went wrong**: during WEB-24 (2026-10-13), `tsc -b` ran for 15+ minutes without finishing
  after a union type (codes or filter) was spread straight into a `supabase.rpc("…", { ...args })`
  call: the generated `Database` types make every overload check expand the union against every
  RPC signature.
- **Rule**: build RPC arguments as a typed variable first (`const args: RpcArgs<"name"> = …`) and
  pass that; never spread a union into `supabase.rpc(...)`. If `pnpm web:typecheck` suddenly takes
  minutes, look for a new RPC call with inline union arguments.
- **Enforced by**: nothing yet; the pre-push hook's typecheck step would hang visibly.

### Check what production serves, not what Vercel says it shipped
- **What went wrong**: `web-smoke.yml` failed after 9 minutes on `e9f74af`/`a346956` and again on
  `f683280` ("No successful Vercel Production deployment"), and both times an empty "redeploy"
  commit was pushed to fix a deploy that hadn't failed: the production `budgets` chunk already had
  the new code. Vercel's Git integration had built it but posted no GitHub Deployment or "Vercel"
  status for the commit, so the wait loop saw `none` until it timed out.
- **Rule**: verify a deploy by asking the deployed thing which commit it is. Each web build stamps
  `<meta name="ledger-build">`; the smoke job passes when production serves the pushed commit or a
  newer one. Before pushing a "redeploy", check the live site (the stamp, or grep a chunk for the
  new code).
- **Enforced by**: `web-smoke.yml` "Wait for production to serve this commit"; `apps/web/vite.config.ts`
  `buildStamp`.

### Git hooks export `GIT_DIR`: in a worktree, every child git uses the wrong repository
- **What went wrong**: pushing the App Review change to `main` from a worktree, the pre-push
  release step (`publish-build.sh`) failed twice with "Couldn't check out revision …: unable to
  read tree" for every Swift package. Git runs hooks with `GIT_DIR` set, and in a worktree it is
  the absolute `.git/worktrees/<name>`, so SwiftPM's own `git` calls inside its package cache
  read this repository instead. From the main checkout `GIT_DIR` is a relative `.git`, which
  happens to resolve inside each package clone, so it never showed there. Reproduced with
  `GIT_DIR=$(git rev-parse --absolute-git-dir) xcodebuild -resolvePackageDependencies` (9 errors;
  0 without it).
- **Rule**: a hook that runs tools which use git themselves (SwiftPM, xcodebuild, npm, uv)
  unsets `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and `GIT_COMMON_DIR` after `cd`-ing to
  the repo root. Don't work around a hook failure with `SKIP_RELEASE=1`; find what the hook's
  environment changes.
- **Enforced by**: `scripts/hooks/pre-push` unsets them at the top; verified by running the hook
  with `GIT_DIR` set and a cold `LedgerKit/.build`.


### Beta App Review must be able to sign in: keep a demo account
- **What went wrong**: TestFlight builds 3 and 6 were rejected under Guideline 2.1(a) ("unable
  to successfully access all or part of the app"). Sign-in was email code or passkey only, the
  review information said "contact us for a test sign-in", and Apple doesn't. Builds 7–12 then
  sat unsubmitted behind build 6's review, so the rejection went unnoticed for days.
- **Rule**: the app keeps a username + password path that the reviewer can use, and Beta App
  Review Information always holds a working demo account whose ledger shows every screen with
  data (synthetic, isolated: `private.create_review_demo`, PRODUCTION §7 step 5).
- **Enforced by**: `testflight-distribute.mjs` refuses to submit a build while Beta App Review
  Information has no demo account; pgTAP `32_review_demo`; `PasswordSignInTests`.

### A bank logo is the bank's own file, downloaded, never drawn
- **What went wrong**: adding Wio, the logo was built by lifting the wordmark paths out of
  wio.io's inline SVG, recolouring them and rasterising a new PNG with resvg. The user rejected
  it: they wanted the bank's actual logo, found online and used as published.
- **Rule**: search for the bank's published logo (its site's `logo.png`, `apple-touch-icon`,
  press kit, or a Wikimedia file) and download that file. Don't redraw, recolour, re-render or
  compose a mark. Record the source URL in `assets/banks/README.md`. If no usable file exists,
  say so and ask; don't make one.
- **Enforced by**: `assets/banks/README.md` ("Downloaded, never drawn"); not mechanically
  checkable.

### A recursive search reads every file under its root, secret files included
- **What went wrong**: looking for Gmail OAuth code, `grep -rniE "gmail|oauth" supabase/functions …`
  printed values from `supabase/functions/.env` and `.env.production`. The guard denied `cat`,
  `grep` and `Read` of a secret file named on the command line, but a recursive search names
  only a directory, so it went through.
- **Rule**: search code with `rg PATTERN DIR` (it skips gitignored files, so every secret file of
  CLAUDE.md §11.4). `grep -r` and `find … -exec cat` over a directory that holds a `.env*`
  (other than `.env.example`), `.env.cutover` or `Secrets*.xcconfig` must exclude them:
  `--exclude='.env*' --exclude='Secrets*.xcconfig'`, `find DIR -not -name '.env*' …`. Never
  `rg -uu`/`--no-ignore --hidden` over such a directory. If a value did print, it is leaked:
  ask the user to rotate it.
- **Enforced by**: `.claude/hooks/guard.py` (`check_recursive_search`: denies recursive
  `grep`/`egrep`, `rg` that searches ignored hidden files, and `find` with `-exec`/`xargs` into a
  reader when a search root contains a secret file that the command does not exclude; the known
  secret directories count even on a clean clone), tested by `guard_test.py`.

### Closing a review is not fixing the data: a total counts what the review was about
- **What went wrong**: after the FAB re-parse incident the 110 orphaned-transaction reviews were
  dismissed, but the orphaned rows stayed in the ledger, and `activity_summary` summed every
  non-void row (`v_spend` already counted only pending and posted). The Activity net read AED
  796.13 in credit while the cards owed about 3,568. Found by reconciling each account's
  statements (opening + lines = closing) against its transactions, statement by statement.
- **Rule**: after an incident, check the money, not the review queue: per account, the latest
  statement's closing balance must equal the first opening balance plus every live transaction
  on the statements in between. Every money total counts pending and posted rows only. A sum of
  transactions is never a balance: balances come from `v_account_balances`.
- **Enforced by**: `20261012043206` (dismissing an orphan review voids it; `activity_summary`
  counts pending and posted; `private.void_orphan_duplicates`); pgTAP `31_outstanding_balance`.

### A row's identity hash names its parent: moving the row means re-keying it
- **What went wrong**: `statement_lines.line_key` hashes the account. `merge_accounts` moved a
  FAB account's lines without re-keying them, so the first re-parse afterwards (parser
  2026.10.7) saw every moved line as new: 115 lines superseded, their transactions orphaned and
  re-created, 5 VAT lines held as ambiguous. A local re-parse test passed because it never
  merged accounts first.
- **Rule**: before moving rows between parents, check whether any stored key or hash includes
  the parent; recompute it in the same statement. Before a production re-parse, check that every
  current line's key equals `private.statement_line_key(...)` for its account (masked lines hash
  `private.masked_originals.original`).
- **Enforced by**: `merge_accounts` re-keys (`20261011172405`); pgTAP `28_merge_accounts`
  (re-parse after a merge supersedes and adds nothing; every key equals the helper's).

### Only a purchase line's two amounts are a conversion rate
- **What went wrong**: FAB prints "VAT ON SERVICE CHARGES" beside the foreign purchase's
  currency and amount (USD 23.20) with only the VAT in AED (0.16). The parser took the pair as a
  conversion (0.00689655 AED/USD), and `estimate_fx` used the latest USD statement rate as the
  truth: three SIB USD purchases (USD 266.47) showed as AED 1.83. Found by listing a year of
  foreign transactions with their rates, not by any test.
- **Rule**: a rate comes only from a current purchase, refund or cash-advance line. A fee row's
  foreign amount is the purchase it belongs to; parse VAT as AED. When checking FX, eyeball
  the implied rate per currency: anything far off the mid rate is a parsing bug.
- **Enforced by**: parser 2026.10.7 (`fab.py` `_VAT_ROW_RE`, synthetic `fab_statement` VAT row);
  `estimate_fx` filters `kind` and `is_current`; pgTAP `05_fx_rates` (a FAB fee line's rate is
  ignored; the posted SIB estimate stores its rate).

### An FX estimate uses the card's own bank, never another bank's rate
- **What went wrong**: an SIB INR 28,400.00 purchase showed AED 1,147.83; SIB billed AED
  1,123.72. `private.estimate_fx` took the profile's latest INR statement rate from any bank, so
  another card's markup (and date) priced the SIB transaction. SIB prints no rate anywhere, so
  its foreign rows always fall through to the estimate.
- **Rule**: an FX estimate is per bank: that bank's own statement rate, else the mid-market rate
  (USD peg or `fx_rates`) times the bank's all-in markup (`private.bank_fx_fees`: network
  charge + bank fee). Derive it from the bank's published fee and check it against a real billed
  amount (the SIB model reproduces its bill to AED 0.03). Use the mid rate of the transaction's
  own (posting) date, not today's: a week of rupee drift was worth 0.65%. A fee table's wording
  ("including any processing fee") is not evidence: ADCB's "all-in" 2.99% bills as 4.17%. Check
  each markup against the bank's printed USD rows (peg × markup) before trusting it.
- **Enforced by**: `estimate_fx` takes the bank (the bank-blind overload is dropped);
  pgTAP `05_fx_rates` (SIB ignores the ADCB rate on the same profile; the real SIB case;
  every bank has a markup row).

### A filter on the phone loses data for good: send it, classify on the server
- **What went wrong**: "Log Bank SMS" ran a regex on the phone to decide "credit card or not"
  before sending. Three ENBD purchase alerts on 2026-10-09 came back "Skipped: not a
  credit-card transaction" and production `sms_messages` had 0 rows ever. Nothing was stored, so
  there was nothing to audit: neither the text nor what the Shortcut had actually passed (the
  real alert passes the filter, so the Shortcut most likely handed over the wrong field).
- **Rule**: a client drops only what must never leave it (OTPs, empty input) and sends the rest;
  the server stores every message first and classifies it from data (`process_sms` templates:
  `ignored` / `unparsed` + LLM fallback). Keep a diagnostic trail on the device that holds no
  content (Settings → Recent captures: outcome, sender, length).
- **Enforced by**: `SMSCaptureTests` (debit, account, no-amount and junk inputs are sent),
  `OutboxTests.recentCaptures`.

### Golden parity is local-only: a worktree (and CI) skip it
- **What went wrong**: parser 2026.10.4 (`b601b67`) changed `merchant_normalized` for glued
  cities. It went to `main` with every check green, because `tests/test_golden_parity.py` skips
  when `services/parser/tests/golden/` is absent, and that folder (private, gitignored) exists
  only in the main checkout, not in worktrees or CI. The main checkout's pre-push then failed
  for the next person who pushed a parser-area change.
- **Rule**: a parser change that alters output runs golden parity against the real snapshots
  before it is pushed: from the main checkout, or in a worktree with a temporary symlink
  (`ln -s <main>/services/parser/tests/golden services/parser/tests/golden`, removed after).
  An intended output change becomes a documented `ALLOWED_DELTAS` entry, never a loosened assert.
- **Enforced by**: nothing yet. Candidate guard: pre-push warns when the parser area changed
  and `tests/golden/` is missing but the main checkout has it.

### `supabase config push` has no dry run and pushes the whole file
- **What went wrong**: `supabase config push` sends the **whole** `supabase/config.toml` to the
  remote project and does not ask for confirmation when stdin isn't a TTY (piping `n` does not
  stop it). Run to "see the diff", it overwrote production auth (`site_url`, email
  confirmations, OTP length, MFA) with local values, which had to be restored.
- **Rule**: never run it to preview anything; there is no dry run. Production-only values are
  pinned in the `[remotes.production]` block at the end of `config.toml`: any value that
  differs between local and prod goes there in the same commit. Pushing is a production action:
  explicit yes in chat, run from the repo root (`--workdir` from elsewhere silently picks up the
  cwd's config), then verify with `GET /auth/v1/settings`. Don't break what it carries: email
  sign-in is code-only (`supabase/templates/` use `{{ .Token }}`; no links, no passwords), and
  passkeys use `rp_id = <web-host>` with the AASA file at
  `apps/web/public/.well-known/apple-app-site-association`. Changing `rp_id` strands every
  passkey. Detail: `supabase/CLAUDE.md`.
- **Enforced by**: `.claude/hooks/guard.py` asks before `supabase config push`.

### A push to `main` is a production deploy
- **What happens**: `main` has no reviewer gate (GitHub Free plan, `AUTO_DEPLOY=true`). A push
  that touches `supabase/` runs `db push` + `functions deploy` on `cc-statement-scraper`; one that
  touches `services/parser/` deploys Cloud Run; every push builds Vercel Production; and when the
  iOS app changed, the pre-push hook archives, signs and stages a TestFlight build that goes to
  external testers. Merging a PR into `main` is the same thing.
- **Rule**: pushing or merging to `main` needs an explicit yes in chat, like `supabase db push`.
  Say what will deploy (areas, migrations, functions, iOS build) when asking. Feature branches and
  PRs are not production. See `docs/ci-cd.md`.
- **Enforced by**: `.claude/hooks/guard.py` asks before any push to `main`, force push or deploy.

### Stage explicit paths; `git add -A` commits other people's work
- **What went wrong**: `f530ca1` ("iOS: rename to Bank Ledger; TestFlight release scripts") also
  deleted 189 files of `backend/` and the root `.dockerignore`. That deletion had been staged in
  the shared checkout by a different piece of work, and a blanket stage swept it into an
  unrelated iOS commit.
- **Rule**: `git add <path> <path>`, never `git add -A`, `git add .`, `git add -u` or
  `git commit -a`. Before every commit, read `git diff --cached --stat` and account for every
  path. Several sessions and worktrees share this repository (and its stash): leave anything you
  did not change alone.
- **Enforced by**: `.claude/hooks/guard.py` (denies the blanket forms).

### A secret that reached a transcript is a secret to rotate
- **What went wrong**: the Anthropic API key and the Sentry org auth token appeared in chat
  transcripts and logs during development, so both had to be rotated before cutover
  (`docs/audit/BACKLOG.md`, "Do before / at cutover" 1).
- **Rule**: secrets live only in the gitignored files listed in CLAUDE.md §11.4. Never `cat`,
  `echo`, `grep` (without `-c`/`-q`), `printenv` or `Read` them. Check shape, not value:
  `cut -d= -f1 FILE` for key names, `grep -c '^KEY=' FILE` for presence, or test a property
  (starts with `https://`, has no `<`) without printing it, as audit X-01 did. Push values with
  the prompted or file-based tools (`gh secret set NAME` with no `--body`,
  `scripts/cutover/set-edge-secrets.sh`), never on a command line. If a value does leak, say so
  and ask the user to rotate it.
- **Enforced by**: `.claude/hooks/guard.py` (denies printing secret files, env dumps, token
  echoes, `Read` of secret files); `scripts/hooks/pre-commit` (refuses staging `.env*`,
  `*.p8`, `*.p12`, `Secrets*.xcconfig`).

### Clients hold the publishable key; only Edge Functions hold the secret key
- **Rule**: web, iOS and the scraper use only the Supabase publishable key (`sb_publishable_…`);
  RLS and the user's JWT do the rest. Edge Functions get the secret key from the
  runtime-injected `SUPABASE_SECRET_KEYS` through `_shared/supabase.ts` (`resolveApiKey`), never by
  reading `SUPABASE_SERVICE_ROLE_KEY` directly. The secret key otherwise exists only in
  `.env.cutover` for one-off admin scripts, sent as `apikey`, never from a browser.
- **Enforced by**: `apps/web/src/lib/supabase-key.ts` + `supabase-key.test.ts` and iOS
  `LedgerConfig` refuse an `sb_secret_` key; `supabase/functions/_tests/api_keys_test.ts`.

### Never push an env file "as is"
- **What went wrong** (audit X-01): the cutover runbook pushed the whole local
  `supabase/functions/.env.production` with `supabase secrets set --env-file`; the file held a
  placeholder `PARSER_URL`, which would have broken every parse right before the canary.
- **Rule**: function secrets go through `scripts/cutover/set-edge-secrets.sh`, which refuses
  empty or `<placeholder>` values, local-only keys and a non-https `PARSER_URL`. A secrets push is
  a production action: ask first.

### Never `REVOKE EXECUTE`: on PG 17.6.1.104 the call segfaults the server
- **What went wrong**: on Supabase Postgres 17.6.1.104 (production's build), calling a function
  the caller lacks EXECUTE on crashes the server (reproduced locally on 2026-10-08).
- **Rule**: guard in the body (`perform private.assert_service_role();` or
  `perform private.assert_member(p_profile_code, need_owner);`); keep internals in `private`.
- **Enforced by**: `supabase/tests/01_rls.test.sql` ("no public/authz function has EXECUTE
  revoked").

### Policies read `= any ((select f())::text[])`, and both halves matter
- **Rule**: `profile_code = any ((select authz.my_profile_codes())::text[])`. The `(select …)`
  makes Postgres evaluate the membership function once per statement (an initplan) instead of
  once per row. The `::text[]` cast makes the scalar subquery an array expression; without it
  `= any (select …)` is parsed as `ANY (subquery)` and compares `text` with `text[]`.
  Copy an existing policy in `20261008000200_identity.sql`; don't hand-write a variant.

### Local green is not prod green: prod has older default privileges
- **What went wrong** (audit FV-01): production was created with Supabase's older default
  privileges (`GRANT ALL ON TABLES TO anon, authenticated`). Local and CI stacks are restricted,
  so every v2 table would have reached prod with table-wide client grants while all 503 local
  pgTAP tests passed.
- **Rule**: grant clients exactly what they need, per column for updates; never rely on
  defaults. When a migration changes a client grant, update the matrix in
  `supabase/tests/11_privileges.test.sql` in the same commit.
- **Enforced by**: `11_privileges.test.sql`; the quarantine migration revokes the defaults first.

### `migration up` matches versions, not contents: reset before pgTAP
- **What went wrong** (audit FV-04, X-31): the shared local stack ran stale bodies of four
  migrations that had been edited after it applied them, and pgTAP failed on a stack holding a
  `legacy` schema and extra data.
- **Rule**: `supabase db reset && supabase test db` from a fresh reset, every time. Once a
  migration is on `origin/main` it is immutable: fix forward with a new one.
- **Enforced by**: pre-commit, pre-push and CI (`scripts/ci/check-migrations.sh`) refuse edits to
  migrations on `main`; `deploy-supabase` compares applied migrations with the files.

### The `legacy` schema and the leftover `backend/` folder are kept
- **Rule**: the `legacy` schema in production is the historical record of v1: read-only, never
  written, dropped or truncated, and the migrations that reference it (quarantine, legacy import,
  parity report) stay as applied history. The tracked v1 code is gone, but the main checkout still
  has an untracked `backend/` folder (`backend/data/` with private statement PDFs and backups,
  `backend/logs/`) and a root `data/`: never delete or "clean up" either.
- **Enforced by**: `.claude/hooks/guard.py` (denies dropping or writing `legacy`, `rm -r` of
  `backend/` or `data/`).

### A broad `.gitignore` rule hides source: check new paths with `git check-ignore`
- **What went wrong**: the root `data/` rule (for private statement PDFs) silently hid
  `apps/web/src/data/`, the web data layer, until `!apps/web/src/data/` was added. The trailing
  `.env*` rule likewise re-ignores `.env.example` files that are not already tracked, so a new
  `supabase/functions/.env.example` (BACKLOG X-16r) would not be added.
- **Rule**: when you create a directory or file whose name a broad rule might match (`data`,
  `build`, `dist`, `logs`, `tmp`, `downloads`, `.env.example`), run
  `git check-ignore -v <path>` and check `git status` lists it before committing.

### Sentry is off in local, dev and test; the real projects are `credit-card-ledger-*`
- **Rule**: every runtime reports only for a deployed environment: with a DSN and an environment
  that is not `''`, `local`, `development` or `test` (iOS also `dev`, `debug`, and never a Debug
  build). Never set a deployed environment name locally to "test Sentry". The projects (org
  `melting-moments`) are `credit-card-ledger-backend` (Edge `service=edge`, parser
  `service=parser`) and `credit-card-ledger-apps` (web `app=web`, iOS `app=ios`). The old
  `ledger-apps`/`ledger-backend` slugs never existed: source-map and dSYM uploads to them failed
  with "Project not found" (`221ea5a`).
- **Enforced by**: `supabase/functions/_tests/sentry_local_test.ts`, `apps/web/src/lib/sentry.test.ts`,
  `AuditFixTests.swift` (`Telemetry.shouldStart`).

### App Store processing rejects "iPhone" in App Intent text (ITMS-90626)
- **What went wrong**: TestFlight build 2 was rejected during processing because the
  `LogBankSMSIntent` description said "iPhone".
- **Rule**: App Intent titles, descriptions, parameter text and App Shortcut phrases never name
  an Apple device or trademark ("iPhone", "iPad", "Siri"). Say "this device" or "your phone".

### Green tests are not a working feature: run it and look at it
- **What went wrong**: the 2000/page option passed every test and silently showed at most 1000
  rows per page, because PostgREST's `max_rows` capped the response (audit X-07). A rejected
  iOS session showed a signed-in "Couldn't load: You are signed out" screen that no test
  covered. Both were found only by running the app.
- **Rule**: before calling a change done, run it: `pnpm check` (the CI mirror for the areas you
  touched), then the thing itself (web in a browser, iOS in the simulator, a function with
  `curl` against the local stack) and look at the result. Say which checks ran and which were
  skipped.

### Tooling defaults that don't work here: `gh` account, Supabase MCP, `localhost`, pip
- **`gh`**: the active account (`h-abbasi`) cannot see `hussu97/cc-statement-scraper`. Use
  `GH_TOKEN=$(gh auth token --user hussu97) gh …`, inline, never printing the token.
- **Supabase MCP**: the connector sees only the organisation it was connected with; it once
  showed another project. Run `list_projects` first: if `<project-ref>` is listed,
  read-only `execute_sql` is fine (2026-10-11, after a reconnect); otherwise use the Supabase CLI
  (linked to `<project-ref>`). Ask before anything that writes, either way.
- **`localhost`**: curl local services at `127.0.0.1` (`http://127.0.0.1:54321/…`); the parser's
  local allow-list and the docs use `127.0.0.1`.
- **Python**: environments are made with `uv` (`uv venv --python 3.12 .venv`, then
  `uv pip sync`/`uv pip install --python .venv/bin/python …`, as in the service READMEs and CI),
  not `pip install` into whatever Python is on the PATH.
