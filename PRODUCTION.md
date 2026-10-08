# Production — Ledger v2

This is the free-tier deployment plan and operations guide for Ledger v2, with a record of the
cutover from legacy v1 (§10). Read [ARCHITECTURE.md](ARCHITECTURE.md) first.

> **Production data is irreplaceable.** Never push migrations, deploy functions or run writes
> against the production project without an explicit go-ahead (CLAUDE.md §11). The `legacy`
> schema is the historical record of v1: never write to it.

---

## 1. Services

| Service | Platform (free tier) | Identifier |
|---|---|---|
| Database, Auth, Storage, Edge Functions, Realtime, Vault, pg_cron, pgmq | Supabase Free | project **`cc-statement-scraper`**, ref **`nkmylznisjcnmqbxosey`** (also holds the read-only `legacy` schema) |
| Statement parser | GCP Cloud Run | GCP project `credit-card-scraper-ht`, service `ccs-parser`, region `me-central1` (Doha), min instances 0 |
| Web app | Vercel Hobby | root directory `apps/web` |
| iPhone app | TestFlight | bundle `com.hussu97.ledger`, team `2F94NY8R3T` |
| Gmail push | GCP Pub/Sub | topic `ccs-gmail-push`, push subscription → `gmail-push` function |
| Outlook | Azure app registration (personal accounts) | polled by `outlook-poll` |
| Error tracking | Sentry (free) | projects `ledger-backend`, `ledger-apps` |
| LLM | Anthropic API | `ANTHROPIC_API_KEY` (optional; costs a few cents a month) |
| Scraper | Local laptop | `scraper/` CLI |

**Free-tier limits to watch:**
- 500 MB database and 1 GB Storage. The PDFs are the bulk.
- 500k Edge Function invocations a month. The worker kick only calls the worker when a queue
  has work.
- The project pauses after 7 idle days. Daily SMS and cron traffic keep it awake, and
  `ops-heartbeat` alerts if it pauses.

**Tooling:**
- Supabase CLI ≥ 2.100, `gcloud`, Node 20 + pnpm, Deno 2, Python 3.12 + uv, Xcode + XcodeGen.
- `psql` (or the Supabase SQL editor) for Vault and one-off SQL.

```bash
supabase login
supabase link --project-ref nkmylznisjcnmqbxosey     # asks for the DB password
```

---

## 2. Supabase

### 2.1 Postgres version (upgrade recommended)

The project runs **Postgres 17.6.1.104**. On this build, calling a function the caller lacks
EXECUTE on **segfaults the server**. v2 never uses `REVOKE EXECUTE` and guards every RPC in its
body instead, so it is safe as is. Still, a crash-on-call bug in production Postgres is worth
leaving behind:

1. Dashboard → Project Settings → Infrastructure → **Upgrade** to the latest offered 17.x
   image. Do it during the cutover freeze (§10, step 3), after the backup: it restarts the
   database (a few minutes of downtime).
2. After the upgrade, re-run the repro on a scratch function (create, revoke from
   `authenticated`, call as `authenticated`). Expect `permission denied`, not a crash. Record
   the result in CLAUDE.md §1.6. Keep the in-body guards either way.

### 2.2 Auth

Dashboard → Authentication:
- **URL Configuration.** Site URL is the Vercel production URL. Add redirect URLs for the
  Vercel domain(s) and `http://127.0.0.1:5173` if you want to test magic links against prod.
- **Providers → Email** enabled (email OTP or magic link). Sign in with Apple isn't used yet.
- **Sign-ups: off, always.** Authentication → Sign In / Providers → *Allow new users to sign
  up* = **off** (local `supabase/config.toml` has `[auth] enable_signup = false` to match). A
  signed-up stranger could create ledgers and use storage, LLM and queue capacity, so Ledger
  never accepts self-registration. The web's magic link no longer creates users
  (`shouldCreateUser: false`); an unknown email is told to ask a ledger owner for an invite.
- **Adding a member** (sign-ups stay off):
  1. An owner adds the email: web Settings → Members (`add_profile_member`). If the email has
     no Auth user yet this stores a **pending invite**.
  2. Create the Auth user: Dashboard → Authentication → Users → **Invite user** with that email
     (or the admin API `auth.admin.inviteUserByEmail`). Invites work with sign-ups disabled. The
     `auth.users` insert trigger claims the pending invite, so the person lands in the ledger
     with the stored role.
  3. They open the invite email (or request an email code) and sign in.

  If the email already has an Auth user, step 1 adds them directly (`added`) and step 2 is
  skipped. An in-app invite that sends the email itself is on the backlog
  ([docs/audit/BACKLOG.md](docs/audit/BACKLOG.md)).
- **SMTP.** The built-in sender is heavily rate-limited (a few emails an hour). That is fine for
  two people. Configure custom SMTP if OTP emails go missing.

### 2.3 Database migrations

```bash
supabase db push --dry-run          # lists the migrations that would run
supabase db push                    # applies supabase/migrations/* in order
```

- The first migration, `20261008000000_quarantine_legacy.sql`, **moves every legacy table and
  enum from `public` into a `legacy` schema**, only when `public.alembic_version` exists. It ran at the cutover (§10
  step 4) and is a no-op on a fresh database.
- The migrations also:
  - enable the extensions `pg_trgm`, `pgmq`, `pg_cron` and `pg_net`
  - create the private Storage bucket **`statements`** (25 MB, `application/pdf`)
  - create the pgmq queues (`parse_document`, `llm_categorize`, `sms_fallback`, each with a
    `_dlq`)
  - schedule the pg_cron jobs (§2.6)
  - add the Realtime publication
- `supabase/seed.sql` is **local only**. `db push` never runs it.

The **Deploy Supabase** workflow (§9) does the same from GitHub.

### 2.4 Vault secrets

Two Vault secrets drive every pg_cron → Edge call: `project_url` and `edge_cron_secret`.
`edge_cron_secret` **must be the same value** as the `CRON_SECRET` function secret (§2.5), so
both come from one place: the `CRON_SECRET=` line of the gitignored
`supabase/functions/.env.production`. Generate it once, never inline:

```bash
# Only if the file has no CRON_SECRET yet (it does today; never regenerate during the cutover):
#   printf 'CRON_SECRET=%s\n' "$(openssl rand -hex 32)" >> supabase/functions/.env.production
export CRON_SECRET="$(grep '^CRON_SECRET=' supabase/functions/.env.production | cut -d= -f2-)"

psql "$LEDGER_DB_URL" -X -q \
  -v project_url=https://nkmylznisjcnmqbxosey.supabase.co \
  -v edge_cron_secret="$CRON_SECRET" \
  -f scripts/cutover/set-vault-secrets.sql
```

- The template ([scripts/cutover/set-vault-secrets.sql](scripts/cutover/set-vault-secrets.sql))
  holds no values. It refuses empty, placeholder (`<…>`) or short secrets and uses
  `private.vault_upsert`, so re-running it updates instead of failing.
- Never run it with `psql -a`/`-e`: they echo the interpolated secret.
- Setting `edge_cron_secret` switches the cron calls on. Do it only after the functions are
  deployed and their secrets are pushed (§10 step 6).
- To check Vault matches the function secret without printing either, compare
  `select encode(extensions.digest(decrypted_secret, 'sha256'), 'hex') from vault.decrypted_secrets where name = 'edge_cron_secret';`
  with `printf %s "$CRON_SECRET" | shasum -a 256`.

Per-profile and per-mailbox secrets are written through RPCs, never by hand:

| Vault name | Written by | Read by |
|---|---|---|
| `profile:<prf_…>:FAB_PDF_PASSWORD` … `MASHREQ_PDF_PASSWORD`, `ADCB_CID` | web Settings → PDF passwords (`set_profile_secret`) | worker → parser `settings` |
| `mailbox:<mbx_…>:refresh_token` | web Settings → Sources → mailbox → Set refresh token (`set_mailbox_secret`) | gmail-push, gmail-watch-renew, outlook-poll |

### 2.5 Edge Functions

Function secrets (`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are
injected automatically) have **one source of truth**: the gitignored
`supabase/functions/.env.production`. Complete it, then push it with
[`scripts/cutover/set-edge-secrets.sh`](scripts/cutover/set-edge-secrets.sh). Never type
secrets inline and never push a file that still holds placeholders.

| Key | Where the value comes from | In the file today |
|---|---|---|
| `CRON_SECRET` | generated once (`openssl rand -hex 32`); the same value goes to Vault `edge_cron_secret` (§2.4) | yes |
| `PARSER_SECRET` | the Secret Manager `parser-secret` value (identical to `services/parser/.env.production`) | yes |
| `PARSER_URL` | the URL printed by the parser deploy (§3), **only after it has deployed** | placeholder |
| `ANTHROPIC_API_KEY`, `LLM_MODEL` | Anthropic console | yes |
| `SENTRY_DSN`, `SENTRY_ENVIRONMENT` | Sentry `ledger-backend` DSN; `production` | yes |
| `SENTRY_RELEASE` | the commit being deployed: pass `--sentry-release "$(git rev-parse --short HEAD)"` (the Deploy Supabase workflow also sets it) | placeholder |
| `GMAIL_OAUTH_CLIENT_ID`, `GMAIL_OAUTH_CLIENT_SECRET` | the Google OAuth client (§5) | missing |
| `MS_OAUTH_CLIENT_ID`, `MS_OAUTH_CLIENT_SECRET` | the Azure app registration (§6); moved from the legacy DB at cutover | missing |
| `GMAIL_PUSH_AUDIENCE` | `https://nkmylznisjcnmqbxosey.supabase.co/functions/v1/gmail-push` | missing |
| `GMAIL_PUSH_SA_EMAIL`, `GMAIL_PUBSUB_TOPIC` | §5: `ccs-gmail-push@credit-card-scraper-ht.iam.gserviceaccount.com` (or the reused relay SA), `projects/credit-card-scraper-ht/topics/ccs-gmail-push` | missing |
| `ALLOWED_ORIGINS` | the Vercel production URL(s), comma-separated | missing |

```bash
# 1. Fill in the missing lines with an editor (not `echo`, which lands in shell history).
# 2. Check without pushing — prints key names only, refuses empty/<placeholder> values:
scripts/cutover/set-edge-secrets.sh --dry-run --sentry-release "$(git rev-parse --short HEAD)"
# 3. Push (asks you to type the project ref):
scripts/cutover/set-edge-secrets.sh --sentry-release "$(git rev-parse --short HEAD)"
supabase secrets list --project-ref nkmylznisjcnmqbxosey      # names and digests only
```

- The script pushes exactly the keys in the file, through a private temp copy, and never
  prints values. Keys absent from the file are left unchanged in production, so you can push
  early (without the OAuth keys) and push again after step 7. Every push is the complete,
  validated file, so a later push can never reset a good value to a placeholder.
- It refuses to run if `CRON_SECRET`, `PARSER_URL` or `PARSER_SECRET` is missing, if
  `PARSER_URL` isn't `https://` or points at a local host, or if the file contains
  `PARSER_DOCUMENT_BASE_URL` or `LEDGER_E2E` (local only).
- Optional overrides: `MS_OAUTH_TENANT` (`consumers`), `OUTLOOK_LOOKBACK_DAYS`,
  `OUTLOOK_BUDGET_MS`, `WORKER_BUDGET_MS`, `PARSER_TIMEOUT_MS`, `EDGE_WALL_CLOCK_MS`,
  `OPS_SMS_UNPARSED_THRESHOLD`, `OPS_OPEN_REVIEWS_THRESHOLD` and `SENTRY_TRACES_SAMPLE_RATE`
  (see README). Add them to the same file.
- **Worker timing.** Leave `PARSER_TIMEOUT_MS` at its default **75000** (set it explicitly only
  to document it): it must stay above the parser's own 60 s kill (§3) and below Cloud Run's
  120 s request timeout. `EDGE_WALL_CLOCK_MS` is 150000 on the free plan (400000 on paid); the
  worker starts a parse round only if `PARSER_TIMEOUT_MS` + 20 s still fits before it.
- **`SENTRY_ENVIRONMENT` must be `production`.** Unset, `local`, `development` and `test`
  disable Sentry even with a DSN (§8).
- **Never set `PARSER_DOCUMENT_BASE_URL` in production.** It exists for local Docker only.

Deploy every function. Each one's `verify_jwt = false` comes from `supabase/config.toml`:

```bash
supabase functions deploy --project-ref nkmylznisjcnmqbxosey
# statements-upload sms-ingest worker gmail-push gmail-watch-renew outlook-poll ops-monitor fx-rates
```

Smoke test (`CRON_SECRET` exported from the same file as in §2.4):

```bash
export CRON_SECRET="$(grep '^CRON_SECRET=' supabase/functions/.env.production | cut -d= -f2-)"
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://nkmylznisjcnmqbxosey.supabase.co/functions/v1/worker   # 401 without x-cron-secret
curl -s -X POST https://nkmylznisjcnmqbxosey.supabase.co/functions/v1/worker \
  -H "x-cron-secret: $CRON_SECRET" -d '{"sync":true}'                                                         # summary JSON
```

### 2.6 pg_cron jobs (created by migrations)

| Job | Schedule (UTC) | Runs |
|---|---|---|
| `ledger-worker-kick` | every minute | `worker`, only when a queue has visible messages |
| `ledger-recategorize-sweep` | `17 */3 * * *` | stale `rules_version` sweep |
| `ledger-fx-rates` | `0 21 * * *` | `fx-rates` function |
| `ledger-nightly` | `0 22 * * *` (02:00 Dubai) | void released authorisations, recurring detection, insights |
| `ledger-llm-enqueue` | `30 22 * * *` | queue uncategorised merchants for the LLM |
| `ledger-legacy-choices` | `45 22 * * *` | apply staged legacy category choices once per transaction (cutover helper); unschedules itself when nothing is pending or 30 days after staging |
| `ledger-ops-monitor` | `*/15 * * * *` | `ops-monitor` → Sentry plus the `ops-heartbeat` check-in |
| `ledger-gmail-watch-renew` | `0 3 * * *` | `gmail-watch-renew` |
| `ledger-outlook-poll` | `5 * * * *` | `outlook-poll` |
| `ledger-cron-history-purge` | `50 23 * * *` | delete `cron.job_run_details` older than 7 days |

Check job health with `select jobname, schedule, active from cron.job;` and
`select * from cron.job_run_details order by start_time desc limit 20;`.
`ledger-legacy-choices` removes itself (above); `select * from private.legacy_unmatched_choices();`
lists staged choices that never met a v2 line.

**Run-history growth.** pg_cron logs every run in `cron.job_run_details` (about 1.6k rows a day;
the every-minute worker kick alone is 1,440). `ledger-cron-history-purge` (migration
`20261008001800`) keeps 7 days, which is enough for `ops_health`'s `cron_last_success` to see
each daily job.

### 2.7 Dashboard settings to change at cutover

`db push` doesn't manage these. Tick them off in the §10 step listed.

| Setting | Where | Value | When |
|---|---|---|---|
| Postgres version | Project Settings → Infrastructure → Upgrade | latest 17.x (off **17.6.1.104**, which segfaults when a caller lacks EXECUTE, §2.1) | step 3, after the backup |
| API max rows | Project Settings → Data API → *Max rows* | **2000** (the web's largest page size; the default 1000 silently truncates 2000/page). Local `supabase/config.toml` `[api] max_rows` must match | step 4 |
| New user sign-ups | Authentication → Sign In / Providers → *Allow new users to sign up* | **off** (members are invited, §2.2) | before the day (no later than step 4) |
| Site URL and redirect URLs | Authentication → URL Configuration | the Vercel production URL (§2.2) | step 9 |

---

## 3. Parser on Cloud Run

From `services/parser/README.md`. The parser lives in its own GCP project
`credit-card-scraper-ht` (billing linked; Cloud Run, Artifact Registry, Cloud Build and
Secret Manager APIs enabled), Artifact Registry repo `ledger` in `me-central1`
(create once: `gcloud artifacts repositories create ledger --repository-format=docker --location=me-central1 --project=credit-card-scraper-ht`).

```bash
PROJECT=credit-card-scraper-ht; REGION=me-central1; SERVICE=ccs-parser
envval() { grep "^$1=" "$2" | cut -d= -f2- | tr -d '\n'; }   # piped straight into gcloud, never printed

# One time: secrets in Secret Manager, from the gitignored prod env file (the same
# PARSER_SECRET is in supabase/functions/.env.production), and a least-privilege SA.
# If a secret already exists, use `gcloud secrets versions add <name> --data-file=-` instead.
envval PARSER_SECRET services/parser/.env.production | gcloud secrets create parser-secret     --data-file=- --project "$PROJECT"
envval SENTRY_DSN    services/parser/.env.production | gcloud secrets create parser-sentry-dsn --data-file=- --project "$PROJECT"
gcloud iam service-accounts create ccs-parser --project "$PROJECT"
for s in parser-secret parser-sentry-dsn; do
  gcloud secrets add-iam-policy-binding "$s" --project "$PROJECT" \
    --member "serviceAccount:ccs-parser@$PROJECT.iam.gserviceaccount.com" --role roles/secretmanager.secretAccessor
done

# Build and deploy (from services/parser)
gcloud run deploy "$SERVICE" --source . --project "$PROJECT" --region "$REGION" \
  --service-account "ccs-parser@$PROJECT.iam.gserviceaccount.com" \
  --allow-unauthenticated --min-instances 0 --max-instances 3 \
  --cpu 1 --memory 1Gi --concurrency 4 --timeout 120 \
  --set-secrets PARSER_SECRET=parser-secret:latest,SENTRY_DSN=parser-sentry-dsn:latest \
  --set-env-vars SENTRY_ENVIRONMENT=production,SENTRY_RELEASE=$(git rev-parse --short HEAD),PARSER_ALLOWED_HOSTS=nkmylznisjcnmqbxosey.supabase.co
PARSER_URL="$(gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" --format 'value(status.url)')"
echo "$PARSER_URL"; curl -s "$PARSER_URL/health"      # the URL is not a secret
```

- `--allow-unauthenticated` is required. The worker authenticates with `X-Parser-Secret`, not a
  Google identity token. `PARSER_ALLOWED_HOSTS` limits downloads to the project's Storage.
- **Resource limits are on by default; no env vars needed.** Each parse runs in a killable
  child process: 15 MB / 30 pages / 32 MB inflated streams, 30 s CPU, 60 s wall clock, 768 MB
  address space ([parse-v1 → Resource limits](docs/contracts/parse-v1.md#resource-limits)).
  Breaches are the permanent 422s `PDF_TOO_LARGE` / `PARSE_TIMEOUT`. Override only with the
  `PARSER_*` variables in `services/parser/.env.example`.
- **Timeouts nest:** parser kill 60 s < worker `PARSER_TIMEOUT_MS` 75 s < Cloud Run
  `--timeout 120`. Keep `--timeout 120`.
- `--concurrency 4` with `--memory 1Gi`: real statements use far less than the 768 MB child
  cap, but four pathological PDFs at once could exhaust the instance. If parses ever die with
  out-of-memory, drop to `--concurrency 2` (more instances instead; BACKLOG SRV-12).
- After deploying, copy the printed service URL into the `PARSER_URL=` line of
  `supabase/functions/.env.production` (replacing the placeholder) and push it with
  `scripts/cutover/set-edge-secrets.sh` (§2.5). `PARSER_SECRET` there must equal the
  `parser-secret` value; both local prod files already agree.
- The parser runs in **`me-central1`**, in project
  `credit-card-scraper-ht`, image repo `ledger`.
- `--source .` uploads `services/parser` to the Cloud Build bucket. `services/parser/.gcloudignore`
  keeps `.env`, `.env.production`, `.venv/`, `tests/` (including `tests/golden/` PDFs) and
  caches out of that upload; `.dockerignore` keeps them out of the image. Check with
  `gcloud meta list-files-for-upload services/parser` (no `.env*` but `.env.example`). The
  Deploy Parser workflow builds from a clean checkout, so it never sees local env files.
- To rotate the secret: add a new secret version, redeploy the parser, then
  `supabase secrets set PARSER_SECRET=…`. Parses fail as *transient* in between and retry.
- The **Deploy Parser** workflow (§9) builds the image with `services/parser/Dockerfile`, pushes
  it to Artifact Registry and runs the same `gcloud run deploy`.

---

## 4. Web on Vercel

| Setting | Value |
|---|---|
| Root Directory | **`apps/web`** (enable "Include files outside the root directory", since it uses workspace packages). |
| Framework preset | Vite |
| Install command | `pnpm install --frozen-lockfile` (Vercel detects pnpm 10 from `packageManager`) |
| Build command | `pnpm build` (`prebuild` builds `@ledger/tokens`, then `tsc -b && vite build`) |
| Output directory | `dist` |
| Node | 20.x or newer |

**Environment variables** (Production; Preview with `VITE_SENTRY_ENVIRONMENT=preview`):

| Variable | Value |
|---|---|
| `VITE_SUPABASE_URL` | `https://nkmylznisjcnmqbxosey.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | Dashboard → API keys → anon/publishable |
| `VITE_SENTRY_DSN` | `ledger-apps` DSN |
| `VITE_SENTRY_ENVIRONMENT` | `production` |
| `SENTRY_AUTH_TOKEN`, `SENTRY_ORG` | source-map upload (build only) |
| `SENTRY_PROJECT` | `ledger-apps` (also the `vite.config.ts` default) |

The production values are in the gitignored `apps/web/.env.production.local`, which holds
exactly these names: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_SENTRY_DSN`,
`VITE_SENTRY_ENVIRONMENT`, `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT`. Paste them into
Vercel → Settings → Environment Variables (Production), or `vercel env add <NAME> production`
one at a time. `SENTRY_AUTH_TOKEN` must be a Vercel env var: `vite.config.ts` reads it from
`process.env`, which Vite does not fill from `.env*` files.

**Git integration.** A Git-connected Vercel project builds Production on every push to `main`.
The **legacy** project (rooted at the removed `frontend/`) must stay disconnected from Git until
it is deleted (§10 step 12); a build of `main` would fail.

**`apps/web/vercel.json`** (picked up from the Root Directory):
- **SPA rewrite.** TanStack Router uses browser history (`/activity`, `/settings`, …), so every
  path except `/assets/*` falls back to `/index.html`. A missing hashed asset stays a 404
  instead of returning HTML.
- **Caching.** `/assets/*` (content-hashed by Vite) is `public, max-age=31536000, immutable`.
  `index.html` keeps Vercel's default revalidation, so a deploy is picked up immediately.
- **Security headers** on every path: `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: DENY`, a restrictive
  `Permissions-Policy`, and a CSP:
  - `script-src 'self'` plus the sha256 of the inline theme script in `index.html`
  - `connect-src` the project's Supabase URL over `https://` (REST, Auth, Storage, Functions)
    and `wss://` (Realtime), plus Sentry ingest (`*.ingest[.us|.de].sentry.io`)
  - `font-src 'self'` (Inter and Fraunces are self-hosted via `@fontsource`; no Google Fonts)
  - `worker-src blob:` for the Sentry Replay worker; `frame-ancestors 'none'`
- The CSP hard-codes the project ref (`nkmylznisjcnmqbxosey`). If `VITE_SUPABASE_URL` ever
  points elsewhere, update `connect-src`. If the inline script in `index.html` changes, update
  its hash. The vitest guard `src/test/vercel-config.test.ts` fails until both match.

There is no `/api` proxy: the app talks to Supabase directly.

---

## 5. Gmail push

Everything Gmail lives in GCP project **`credit-card-scraper-ht`** (account
`hussainabbasi786110@gmail.com`), which also hosts the parser. The legacy project
`credit-card-scraper-488614` only holds the old OAuth client and an unused topic (see item 6).

**Already provisioned (2026-10-08).** The setup ran these commands; re-run them only to rebuild
it. `PROJECT=credit-card-scraper-ht`, `URL=https://nkmylznisjcnmqbxosey.supabase.co/functions/v1/gmail-push`.

1. **APIs:** `pubsub.googleapis.com` and `gmail.googleapis.com` are enabled.
2. **Topic** `gmail-statements` (7-day retention). `gmail-api-push@system.gserviceaccount.com` has
   `roles/pubsub.publisher` on it, so Gmail can publish:
   ```bash
   gcloud pubsub topics create gmail-statements --message-retention-duration=7d --project $PROJECT
   gcloud pubsub topics add-iam-policy-binding gmail-statements --project $PROJECT \
     --member=serviceAccount:gmail-api-push@system.gserviceaccount.com --role=roles/pubsub.publisher
   ```
3. **Push service account** `gmail-push-invoker@credit-card-scraper-ht.iam.gserviceaccount.com`
   (= `GMAIL_PUSH_SA_EMAIL`). The Pub/Sub service agent
   `service-578220173618@gcp-sa-pubsub.iam.gserviceaccount.com` has
   `roles/iam.serviceAccountTokenCreator` on it, so it can mint the OIDC token.
4. **Push subscription** `gmail-statements-push` → `gmail-push`. The OIDC audience is the function
   URL (= `GMAIL_PUSH_AUDIENCE`). `gmail-push` checks the Google signature, the audience, and
   `email == GMAIL_PUSH_SA_EMAIL`. The ack deadline is 180 s (it must be **≥ 120 s**: a push with
   several PDFs is slow, and a 500 triggers redelivery). Retry backoff is 10 s → 600 s. After 10
   failed deliveries a message goes to the dead-letter topic `gmail-statements-dlq`, which is held
   by pull subscription `gmail-statements-dlq-hold` (7-day retention) for inspection. The Pub/Sub
   service agent has publisher on the DLQ topic and subscriber on the push subscription.
   ```bash
   gcloud pubsub subscriptions create gmail-statements-push --project $PROJECT --topic=gmail-statements \
     --push-endpoint=$URL --push-auth-service-account=gmail-push-invoker@$PROJECT.iam.gserviceaccount.com \
     --push-auth-token-audience=$URL --ack-deadline=180 --message-retention-duration=7d \
     --expiration-period=never --min-retry-delay=10s --max-retry-delay=600s \
     --dead-letter-topic=gmail-statements-dlq --max-delivery-attempts=10
   # Inspect dead letters (does not ack them):
   gcloud pubsub subscriptions pull gmail-statements-dlq-hold --limit=5 --project $PROJECT
   ```
5. **Function secrets** are set (in `supabase/functions/.env.production`, pushed with
   `scripts/cutover/set-edge-secrets.sh`):
   `GMAIL_PUSH_AUDIENCE=$URL`,
   `GMAIL_PUSH_SA_EMAIL=gmail-push-invoker@credit-card-scraper-ht.iam.gserviceaccount.com`,
   `GMAIL_PUBSUB_TOPIC=projects/credit-card-scraper-ht/topics/gmail-statements`.

**Still to do by hand:**

6. **OAuth client in `credit-card-scraper-ht` (required).** Gmail `users.watch` only accepts a
   topic in the **same GCP project as the OAuth client**. The legacy client (project `…-488614`,
   currently set as `GMAIL_OAUTH_CLIENT_ID/SECRET`) can refresh the imported mailbox's token, but
   its watch on the new topic is rejected: on 2026-10-08, `gmail-watch-renew` returned
   `renewed: 0, failed: 1`. Google doesn't let you create Web OAuth clients for an External
   consent screen with gcloud, so do it in the console as `hussainabbasi786110@gmail.com` with
   project `credit-card-scraper-ht` selected:
   1. **APIs & Services → OAuth consent screen** (Google Auth Platform) → *Get started*. App
      name `Ledger`, support email = your Gmail → Audience **External** → contact email →
      agree → *Create*.
   2. **Audience** → keep *Testing* → *Test users* → *Add users* → the Gmail mailbox you ingest
      from → *Save*.
   3. **Data access** → *Add or remove scopes* → paste
      `https://www.googleapis.com/auth/gmail.readonly` → *Add to table* → *Update* → *Save*.
   4. **Clients** → *Create client* → type **Web application**, name `ledger-gmail`. Under
      *Authorised redirect URIs* add `https://developers.google.com/oauthplayground` (v2 has no
      in-app OAuth code exchange: the web app only stores a pasted refresh token through
      `set_mailbox_secret`) → *Create*. Copy the client ID and secret.
   5. Put them in `supabase/functions/.env.production` as `GMAIL_OAUTH_CLIENT_ID=` /
      `GMAIL_OAUTH_CLIENT_SECRET=` (use an editor), then run `scripts/cutover/set-edge-secrets.sh`.
   6. **Mint a refresh token:** open https://developers.google.com/oauthplayground → ⚙ →
      tick *Use your own OAuth credentials* → paste the new ID/secret → in *Step 1* enter
      `https://www.googleapis.com/auth/gmail.readonly` → *Authorize APIs* → sign in as the
      mailbox (continue past the "unverified app" warning) → *Exchange authorization code for
      tokens* → copy the **refresh token**.
   7. **Re-authorise the mailbox:** web Settings → Sources → the Gmail mailbox → *Set refresh
      token* → paste → save. The old token only works with the old client, so steps 5 and 7 go
      together. Until both are done the legacy client stays set and keeps refreshing.
   8. Start the watch (item 7) and confirm `renewed: 1`.

   In *Testing* mode, Google expires refresh tokens after **7 days**. To keep the token, set
   *Audience → Publish app* (in production, a gmail.readonly app used only by its own test users
   works unverified, behind the warning screen). Otherwise repeat 6–7 weekly.
7. **Watch.** `ledger-gmail-watch-renew` renews daily (watches expire after 7 days) on
   `GMAIL_PUBSUB_TOPIC`, using `sync_state.watch_label_ids` (default `["INBOX"]`). Start the
   first watch by hand. `?sync=1` waits and returns `{renewed, failed}`:
   ```bash
   curl -s -X POST "https://nkmylznisjcnmqbxosey.supabase.co/functions/v1/gmail-watch-renew?sync=1" -H "x-cron-secret: $CRON_SECRET"
   ```
   The first push after a watch only stores the history cursor. Later pushes ingest.
8. **Legacy cleanup.** Once the new client is authorised and a watch has renewed, delete these
   from `credit-card-scraper-488614` (as `pilgrimage.tracker@gmail.com`): the topic
   `gmail-statements` (it has no subscription; Gmail was never live there) and the old OAuth
   client (APIs & Services → Credentials). The old refresh token stops working at that point.

## 6. Outlook

1. Reuse the legacy Azure app registration (personal Microsoft accounts) or create one. Grant
   delegated Graph permissions `Mail.Read` and `offline_access`, and create a client secret
   (note its expiry).
2. Set the function secrets `MS_OAUTH_CLIENT_ID` and `MS_OAUTH_CLIENT_SECRET`, plus
   `MS_OAUTH_TENANT` if not `consumers`.
3. Existing refresh tokens were moved into Vault at cutover. A new mailbox needs an auth-code exchange for a
   refresh token with scope `offline_access https://graph.microsoft.com/Mail.Read`, pasted in
   Settings → Sources.
4. `ledger-outlook-poll` runs hourly at :05. Run it once by hand to verify:
   `curl -X POST …/functions/v1/outlook-poll -H "x-cron-secret: $CRON_SECRET"`.

---

## 7. iOS release (TestFlight)

1. Create `apps/ios/Config/Secrets.Release.xcconfig` (gitignored):
   ```
   LEDGER_SUPABASE_URL = https:/$()/nkmylznisjcnmqbxosey.supabase.co
   LEDGER_SUPABASE_ANON_KEY = <anon key>
   LEDGER_SENTRY_DSN = <ledger-apps DSN>
   ```
2. One-time App Store Connect setup (bundle ids `com.hussu97.ledger` + `.share` are already
   registered with App Groups; Xcode assigns `group.com.hussu97.ledger` on the first archive):
   create the app record (*Apps → + → New App*, name **Credit Card Ledger**, bundle id
   `com.hussu97.ledger`; the home-screen name stays "Ledger"), then in
   TestFlight an internal group **Ledger Internal** (automatic distribution) and an external
   group **Friends & Family** (public link), and fill *Test Information* (beta description,
   feedback email, privacy policy URL, review contact incl. phone).
3. Release (same flow as mm-pos; the API key is the one in `~/.appstoreconnect/private_keys`):
   ```bash
   # dSYMs → ledger-apps: SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT from the environment,
   # or (when unset) from Config/Secrets.Release.xcconfig; the token is never printed.
   apps/ios/scripts/testflight.sh                       # test, archive, export, dSYMs, upload
   node apps/ios/scripts/testflight-distribute.mjs      # Friends & Family + Beta App Review
   git commit --only apps/ios/build-number.json …       # testflight.sh bumps it
   ```
   - The script refuses to run without the release xcconfig, or if it points at 127.0.0.1.
   - `apps/ios/scripts/publish-build.sh` instead builds with `--no-upload`, stages the IPA and
     `build-meta.json` on the `ios-ledger-staged` GitHub release for the TestFlight workflow,
     and commits the build number itself.
4. On each phone, after installing from TestFlight:
   - Sign in.
   - Settings → *SMS go to*: pick the ledger SMS and shared PDFs are filed to (owned ledgers
     only).
   - Settings → *Set up SMS capture*: create **one** automation, *Message contains "Card"*,
     with **Run Immediately** and **Notify When Run on** (results such as "unknown card" or
     "not sent" are only visible that way). Don't add "AED" or "ending" automations; each extra
     keyword fires the intent again for the same alert.
   - Tap **Send test** in Settings and check "Last captured" updates.
   - On a real card alert, confirm a pending transaction appears on the web app. Also check
     once that an alert with lowercase "card" (the ENBD refund wording) triggers the
     automation: Shortcuts' case sensitivity is not yet verified (BACKLOG).

---

## 8. Sentry

Two projects (see ARCHITECTURE.md §10):

| Project | Platform | DSN goes to |
|---|---|---|
| `ledger-backend` | Deno / Python | `supabase secrets set SENTRY_DSN=…`, Secret Manager `parser-sentry-dsn` |
| `ledger-apps` | React / Apple | Vercel `VITE_SENTRY_DSN` (+ `SENTRY_PROJECT=ledger-apps` for source maps), iOS `LEDGER_SENTRY_DSN` (+ `SENTRY_PROJECT=ledger-apps` for dSYMs) |

Every event carries the tag `service` (edge | parser) in `ledger-backend` and `app` (web | ios)
in `ledger-apps`, set at SDK init by each runtime. Edge events also carry `function`, parser
events `parser_version`, and iOS events `target` (app | intent | share_extension).

**Local, development and test never report**, in every runtime, even with a DSN set: Edge and
parser skip init when `SENTRY_ENVIRONMENT` is unset, `local`, `development` or `test`; the web
when `VITE_SENTRY_ENVIRONMENT` is empty, one of those, or Vite runs in dev mode; iOS when
`LEDGER_ENVIRONMENT` is one of those (or `dev`) or the build is Debug. Production must set the
environment to `production` (Vercel Preview: `preview`).

**Alerts:**

| Alert | Project | Rule |
|---|---|---|
| New issue | both | Issue alert: "A new issue is created", `environment:production`, notify by email |
| Ops heartbeat | `ledger-backend` | Cron monitor `ops-heartbeat`, auto-created by the first check-in (`*/15 * * * *`, 5 min margin), alert on missed or failed check-in |
| DLQ > 0 | `ledger-backend` | Issue alert: event tag `ops_issue` starts with `dlq:` (from `ops-monitor`), plus worker DLQ error events, any frequency |
| iOS crash-free < 99% | `ledger-apps` | Metric alert: crash-free session rate < 99% over 24 h, filtered `app:ios` (if session alerts can't filter on the tag, filter on the iOS release package `com.hussu97.ledger`) |

Non-production debug triggers to verify delivery (they need a reporting environment such as
`preview` or `ci`, since local never reports):
- Edge: the `?debug_sentry=1` flag.
- Parser: `GET /debug-sentry`, with `X-Parser-Secret`.
- iOS: the Settings → Debug section (Release builds only).
- Web: no trigger yet (ROADMAP).

---

## 9. CI/CD (GitHub Actions)

| Workflow | Trigger | What |
|---|---|---|
| `ci.yml` | PRs, pushes to `main`, manual | Path-filtered jobs:<br>• `supabase`: `supabase start`, `db reset`, `test db`, DB types drift<br>• `edge`: `deno test`<br>• `parser`: ruff, pytest<br>• `web`: tokens check, lint, test, build<br>• `ios`: `swift test` on LedgerKit, macOS; only on LedgerKit/tokens changes or manual runs<br>• `scraper` |
| `deploy-supabase.yml` | **manual only** | `supabase db push` and/or `supabase functions deploy`. Requires typing the project ref to confirm. Runs in the `production` environment. |
| `deploy-parser.yml` | **manual only** | Builds `services/parser`, pushes to Artifact Registry, runs `gcloud run deploy ccs-parser` (min instances 0, secrets from Secret Manager) |
| `security.yml` | weekly, manual | pip-audit and bandit (parser) |

Production deploys are never automatic.

**Guards.**
- `deploy-supabase` and `deploy-parser` run only from `main`: a `guard` job fails any dispatch
  from another ref before the `production` environment gate, and both still need their typed
  confirmation. Also give the `production` environment a deployment-branch policy of
  `main` only (Settings → Environments → production → Deployment branches).

**Merge timing.** `workflow_dispatch` workflows can be dispatched only once the file is on the
default branch, so the deploy workflows need `ledger-v2` merged into `main`. The merge also
deletes `backend/` and `frontend/` from `main`, so first make sure every Git-connected legacy
build is off (§10 step 1): Render `ccs-platform` Auto-Deploy off (or the service deleted) and
the legacy Vercel project disconnected (or deleted). Otherwise they rebuild on the merge and
fail. The new `apps/web` Vercel project builds Production on the merge as usual.

**Permissions.** Every workflow sets `permissions: contents: read` (or none, for the guard).
CI's `changes` job adds `pull-requests: read`, which `dorny/paths-filter` needs to list PR files
in a private repo.

**GitHub secrets.** Create a `production` environment with required reviewers.

| Secret | Used by |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | deploy-supabase (personal access token) |
| `SUPABASE_DB_PASSWORD` | deploy-supabase (`supabase link` / `db push`) |
| `SUPABASE_PROJECT_REF` | deploy-supabase, deploy-parser (`nkmylznisjcnmqbxosey`) |
| `GCP_SA_KEY`, `GCP_PROJECT_ID` | deploy-parser |

The GCP deploy SA needs roles `run.admin`, `artifactregistry.writer` and
`iam.serviceAccountUser` on `ccs-parser@`.

---

## 10. Cutover record

Legacy v1 and v2 shared the Supabase project. The cutover is complete and the legacy code has
been removed from the repo. The full runbook (commands, rehearsal notes, rollback table) is in
git history: `git log --diff-filter=D -1 -- scripts/migrate_legacy.py` finds the commit that
removed the legacy code, and its parent (or `cdd77b1`, the `ledger-v2` head before the
removal) still has the runbook, `backend/` and the cutover script. Other sections refer to the
steps by number:

1. **Freeze legacy:** legacy workflows off (`LEGACY_DEPLOYS_ENABLED=false`), Render
   `ccs-platform` Auto-Deploy off and suspended, legacy Vercel project disconnected from Git,
   Cloud Scheduler `ccs-gmail-watch-renew` paused, Cloud Run `ccs-gmail-relay` left deployed.
2. **Back up:** whole-DB and `public`-data `pg_dump`s plus a GCS bucket listing, kept off-machine.
3. **Upgrade Postgres** (§2.1, §2.7).
4. **Apply the v2 migrations** (`supabase db push`): `…0000_quarantine_legacy` moved every
   legacy table and enum into the `legacy` schema. Data API max rows 2000.
5. **Push function secrets and deploy the functions** (§2.5).
6. **Set Vault** `project_url` and `edge_cron_secret` (§2.4), which switched pg_cron → Edge on.
7. **Migrate data** with the one-off `scripts/migrate_legacy.py` (now removed): metadata
   (profiles, categories, rules, staged category choices, mailboxes, pending member invites),
   secrets (PDF passwords and mailbox refresh tokens into Vault, the MS OAuth client into
   `supabase/functions/.env.production`) and every legacy PDF as `documents(source='legacy')`,
   re-parsed by the worker. Members were then invited through Auth (§2.2).
8. **Drain the worker, check, finalize:** post-import statement checks (now an operations task,
   §11), staged legacy category choices applied, and parity signed off on the
   `legacy_parity_report` (`legacy_lines_missing = 0` for every bank; the explained deltas are
   in docs/audit/02).
9. **Switch the web app** to the `apps/web` Vercel project and update Auth URLs (§2.2, §4).
10. **Point the scraper at v2** (README → Scraper env).
11. **Switch email** to `gmail-push` / `outlook-poll` (§5, §6).
12. **Decommission.** Legacy code removed from the repo: `backend/`, `frontend/`, `deploy/`,
    the legacy workflows and CI jobs, the legacy git hook steps, `docs/operations/`,
    `docs/security/` and `scripts/migrate_legacy.py` (with its tests). Still to do **outside
    the repo**, once legacy has been read-only for 30 clean days:
    - [ ] Delete the Render service `ccs-platform`, the legacy Vercel project, the Cloud Run
      `ccs-gmail-relay` service and its Cloud Scheduler job, and the legacy GCS bucket (export
      it first if you want a cold copy). Until then keep Render **Auto-Deploy off** and the
      legacy Vercel project **disconnected from Git**: both would now try to build a `main`
      without `backend/` or `frontend/` and fail.
    - [ ] `gh variable delete LEGACY_DEPLOYS_ENABLED` (nothing reads it any more).
    - [ ] Shred the cutover-only secrets: `rm -P .env.cutover` and the legacy GCS reader SA key.
      Keep `supabase/functions/.env.production` (or move it to a password manager); it is the
      only place `CRON_SECRET` is readable.
    - [ ] Optionally `select cron.unschedule('ledger-legacy-choices')` (in a migration); it
      also unschedules itself.
    - Dropping the `legacy` schema is a separate, explicit decision. Take a final `pg_dump`
      first. Until then it stays untouched (no client role can read it).

**Rollback.** There is no rollback to legacy from this tree. While the Render service still
exists (suspended), the legacy rollback procedure in the runbook's git history applies (move
the `legacy` tables back to `public`, resume Render, repoint the domain, Pub/Sub and scraper).
After the decommission, restore from the backups of step 2 or the final dump.

**Local secret files** (all gitignored, mode 600; values never go in the repo or the shell
history):

| File | Holds | Used for |
|---|---|---|
| `supabase/functions/.env.production` | every function secret (§2.5), incl. `CRON_SECRET` | function secrets and Vault `edge_cron_secret` (§2.4, §2.5) |
| `services/parser/.env.production` | `PARSER_SECRET` (same value as above), `PARSER_ALLOWED_HOSTS`, `SENTRY_DSN`, `SENTRY_ENVIRONMENT` | Secret Manager `parser-secret` / `parser-sentry-dsn` (§3). Never uploaded (`.gcloudignore`) |
| `apps/web/.env.production.local` | `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_SENTRY_DSN`, `VITE_SENTRY_ENVIRONMENT`, `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT` | Vercel env (§4) |
| `apps/ios/Config/Secrets.Release.xcconfig` | `LEDGER_SUPABASE_URL`, `LEDGER_SUPABASE_ANON_KEY`, `LEDGER_SENTRY_DSN`, `LEDGER_ENVIRONMENT`; optionally `SENTRY_AUTH_TOKEN`/`SENTRY_ORG`/`SENTRY_PROJECT` for dSYMs when the shell doesn't set them (prefer the shell: in the xcconfig the token is also an Xcode build setting, BACKLOG IOS-21) | TestFlight builds (§7) |

---

## 11. Operations

- **Statements with impossible dates** (for example after a parser fix to year or amount
  handling; the cutover's post-import check). As `postgres` in psql, expect 0 rows:
  ```sql
  select a.profile_code, a.bank_code, s.stmt_code, s.doc_code, s.statement_date,
         s.period_start, s.period_end, s.due_date, d.parser_version
  from public.statements s
  join public.accounts a on a.profile_code = s.profile_code and a.account_code = s.account_code
  left join public.documents d on d.profile_code = s.profile_code and d.doc_code = s.doc_code
  where s.status = 'active' and s.kind = 'statement'
    and (s.statement_date > current_date + 31
         or s.period_end - s.period_start > 100
         or s.due_date < s.statement_date);
  ```
  Re-parse the documents (`requeue_documents`, below). A re-parse that corrects the year
  withdraws its evidence from the bad statement, which is retired (`superseded`). If one stays
  `active` (it came from another document), supersede it through one of the `period_overlap`
  reviews that list it, then dismiss the remaining ones:
  ```sql
  select review_code from public.match_reviews
  where status = 'open' and reason = 'period_overlap'
    and candidates @> jsonb_build_array(jsonb_build_object('stmt_code', '<stm_stale>'));
  select public.resolve_review('<rev_one_of_them>', jsonb_build_object('supersede', '<stm_stale>'));
  select public.resolve_review('<rev_each_other>', '{"dismiss": true}'::jsonb);
  ```
- **Re-parse after a parser fix:** deploy the parser, then `select requeue_documents('<prf_…>')`
  as an owner (or from Cards & Statements → documents in the web app). Re-ingest is in place, so codes, categories and
  notes survive.
- **DLQ:** inspect with `select msg_id, message from pgmq.q_parse_document_dlq;` (`dlq_reason`
  is inside `message`). Fix the cause, then:
  - For documents, `requeue_documents` re-queues them.
  - For other queues, use
    `select pgmq.send('<queue>', message - 'dlq_reason' - 'dlq_at') from pgmq.q_<queue>_dlq where msg_id = <id>;`
    then `select pgmq.delete('<queue>_dlq', <id>);`.
- **New SMS format:** add a template row in a guarded content migration (CLAUDE.md §1.9) with
  `examples`. The validation trigger proves it parses, and unparsed messages re-run
  automatically. Or approve an LLM proposal in the Review inbox.
- **Add a member:** owner adds the email in Settings → Members, then Dashboard → Authentication
  → Users → Invite user (§2.2). Sign-ups stay off.
- **Secret rotation:**
  - `CRON_SECRET`: replace the line in `supabase/functions/.env.production`, then run
    `scripts/cutover/set-edge-secrets.sh` and `scripts/cutover/set-vault-secrets.sql` (§2.4)
    back to back. Cron calls get 401 in between.
  - `PARSER_SECRET`: see §3.
  - Service tokens: revoke and re-create in Settings.
  - OAuth clients: rotate in Google or Azure, update the file, then `set-edge-secrets.sh`.
    A new *Google* client invalidates the stored Gmail refresh tokens (§5.4).
  - Mailbox tokens: Set refresh token in Settings.
- **Backups:** the free tier has no downloadable automated backups. Take a monthly
  `supabase db dump --linked -f ledger-$(date +%F).sql` (schema) and `--data-only` (data). The
  PDFs are also on the laptop (`scraper/downloads`) and in email.
- **Pause protection:** if the project pauses, `ops-heartbeat` misses and alerts. Restore it
  from the dashboard.
