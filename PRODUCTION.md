# Production — Ledger v2

This is the free-tier deployment plan for Ledger v2 and the runbook for cutting over from legacy
v1. Read [ARCHITECTURE.md](ARCHITECTURE.md) first.

> **Production data is irreplaceable.** Never push migrations, deploy functions or run writes
> against the production project without an explicit go-ahead (CLAUDE.md §11). Every
> `scripts/migrate_legacy.py` step is a dry run unless you pass `--apply`.

---

## 1. Services

| Service | Platform (free tier) | Identifier |
|---|---|---|
| Database, Auth, Storage, Edge Functions, Realtime, Vault, pg_cron, pgmq | Supabase Free | project **`cc-statement-scraper`**, ref **`<project-ref>`** (the same project legacy uses) |
| Statement parser | GCP Cloud Run | GCP project `<gcp-project>`, service `ccs-parser`, region `me-central1` (Doha), min instances 0 |
| Web app | Vercel Hobby | root directory `apps/web` |
| iPhone app | TestFlight | bundle `com.example.ledger`, team `<apple-team-id>` |
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
supabase link --project-ref <project-ref>     # asks for the DB password
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
     no Auth user yet this stores a **pending invite**. At cutover, `migrate_legacy.py --step
     metadata` stores the two owners' invites the same way.
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
  enum from `public` into a `legacy` schema**, only when `public.alembic_version` exists. The
  legacy backend stops working from this point, so push only inside the cutover freeze (§10).
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
  -v project_url=https://<project-ref>.supabase.co \
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
| `profile:<prf_…>:FAB_PDF_PASSWORD` … `MASHREQ_PDF_PASSWORD`, `ADCB_CID` | web Settings → PDF passwords (`set_profile_secret`), or `migrate_legacy.py --step secrets` | worker → parser `settings` |
| `mailbox:<mbx_…>:refresh_token` | web Settings → Sources → mailbox → Set refresh token (`set_mailbox_secret`), or the cutover script | gmail-push, gmail-watch-renew, outlook-poll |

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
| `GMAIL_OAUTH_CLIENT_ID`, `GMAIL_OAUTH_CLIENT_SECRET` | **Render env** `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID` / `_SECRET` (§5.4). Not in the legacy DB | missing |
| `MS_OAUTH_CLIENT_ID`, `MS_OAUTH_CLIENT_SECRET` | legacy DB, written into this file by `migrate_legacy.py --step secrets` (§10 step 7) | missing |
| `GMAIL_PUSH_AUDIENCE` | `https://<project-ref>.supabase.co/functions/v1/gmail-push` | missing |
| `GMAIL_PUSH_SA_EMAIL`, `GMAIL_PUBSUB_TOPIC` | §5: `ccs-gmail-push@<gcp-project>.iam.gserviceaccount.com` (or the reused relay SA), `projects/<gcp-project>/topics/ccs-gmail-push` | missing |
| `ALLOWED_ORIGINS` | the Vercel production URL(s), comma-separated | missing |

```bash
# 1. Fill in the missing lines with an editor (not `echo`, which lands in shell history).
# 2. Check without pushing — prints key names only, refuses empty/<placeholder> values:
scripts/cutover/set-edge-secrets.sh --dry-run --sentry-release "$(git rev-parse --short HEAD)"
# 3. Push (asks you to type the project ref):
scripts/cutover/set-edge-secrets.sh --sentry-release "$(git rev-parse --short HEAD)"
supabase secrets list --project-ref <project-ref>      # names and digests only
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
supabase functions deploy --project-ref <project-ref>
# statements-upload sms-ingest worker gmail-push gmail-watch-renew outlook-poll ops-monitor fx-rates
```

Smoke test (`CRON_SECRET` exported from the same file as in §2.4):

```bash
export CRON_SECRET="$(grep '^CRON_SECRET=' supabase/functions/.env.production | cut -d= -f2-)"
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://<project-ref>.supabase.co/functions/v1/worker   # 401 without x-cron-secret
curl -s -X POST https://<project-ref>.supabase.co/functions/v1/worker \
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
`<gcp-project>` (billing linked; Cloud Run, Artifact Registry, Cloud Build and
Secret Manager APIs enabled), Artifact Registry repo `ledger` in `me-central1`
(create once: `gcloud artifacts repositories create ledger --repository-format=docker --location=me-central1 --project=<gcp-project>`).

```bash
PROJECT=<gcp-project>; REGION=me-central1; SERVICE=ccs-parser
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
  --set-env-vars SENTRY_ENVIRONMENT=production,SENTRY_RELEASE=$(git rev-parse --short HEAD),PARSER_ALLOWED_HOSTS=<project-ref>.supabase.co
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
- The parser runs in **`me-central1`** (`.env.cutover` `GCP_REGION`), in project
  `<gcp-project>`, image repo `ledger`. The legacy `europe-west1` / `ccs-platform`
  repo belongs to the old project and is only used by the legacy gmail-relay workflow.
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
| Root Directory | **`apps/web`** (enable "Include files outside the root directory", since it uses workspace packages). Never `frontend/` |
| Framework preset | Vite |
| Install command | `pnpm install --frozen-lockfile` (Vercel detects pnpm 10 from `packageManager`) |
| Build command | `pnpm build` (`prebuild` builds `@ledger/tokens`, then `tsc -b && vite build`) |
| Output directory | `dist` |
| Node | 20.x or newer |

**Environment variables** (Production; Preview with `VITE_SENTRY_ENVIRONMENT=preview`):

| Variable | Value |
|---|---|
| `VITE_SUPABASE_URL` | `https://<project-ref>.supabase.co` |
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

**Git integration.** A Git-connected Vercel project builds Production on every push to `main`
from the day it is created. That is harmless before the cutover (it serves only its
`*.vercel.app` URL), but the **legacy** project, rooted at `frontend/`, also builds on every
`main` push until it is disconnected (§10 step 1).

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
- The CSP hard-codes the project ref (`<project-ref>`). If `VITE_SUPABASE_URL` ever
  points elsewhere, update `connect-src`. If the inline script in `index.html` changes, update
  its hash. The vitest guard `src/test/vercel-config.test.ts` fails until both match.

Unlike legacy `frontend/vercel.json`, there is no `/api` proxy: the app talks to Supabase
directly.

Use a **new Vercel project** for `apps/web` and keep the legacy project until §10 step 9, when
the production domain moves.

---

## 5. Gmail push

1. **Topic** (reuse the legacy one): `ccs-gmail-push`, with `gmail-api-push@system.gserviceaccount.com`
   granted `roles/pubsub.publisher` (already done for legacy).
2. **Push service account.** `ccs-gmail-push@<project>.iam.gserviceaccount.com`. Reusing legacy
   `ccs-gmail-relay@…` is fine; set whichever you pick as `GMAIL_PUSH_SA_EMAIL`. The Pub/Sub
   service agent must be able to mint tokens for it:
   ```bash
   gcloud iam service-accounts add-iam-policy-binding ccs-gmail-push@$PROJECT.iam.gserviceaccount.com \
     --member serviceAccount:service-$(gcloud projects describe $PROJECT --format='value(projectNumber)')@gcp-sa-pubsub.iam.gserviceaccount.com \
     --role roles/iam.serviceAccountTokenCreator
   ```
3. **Push subscription.** The OIDC audience must equal `GMAIL_PUSH_AUDIENCE`. The ack deadline
   must be **≥ 120 s**, because a push with several PDFs can take a while and a 500 response
   triggers redelivery.
   ```bash
   gcloud pubsub subscriptions modify-push-config ccs-gmail-push-sub --project $PROJECT \
     --push-endpoint=https://<project-ref>.supabase.co/functions/v1/gmail-push \
     --push-auth-service-account=ccs-gmail-push@$PROJECT.iam.gserviceaccount.com \
     --push-auth-token-audience=https://<project-ref>.supabase.co/functions/v1/gmail-push
   gcloud pubsub subscriptions update ccs-gmail-push-sub --ack-deadline=120 --project $PROJECT
   ```
   For a fresh setup, use `subscriptions create … --topic ccs-gmail-push` with the same flags.
4. **OAuth client.**
   - Function secrets: `GMAIL_OAUTH_CLIENT_ID` and `GMAIL_OAUTH_CLIENT_SECRET`.
   - **Source: the Render env, not the legacy DB.** Legacy reads the Gmail client from
     `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID` and `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_SECRET` (Render →
     `ccs-platform` → Environment); `legacy.runtime_settings` holds only the Gmail *refresh
     token*, so `migrate_legacy.py --step secrets` cannot emit these. Copy both values into
     `GMAIL_OAUTH_CLIENT_ID=` / `GMAIL_OAUTH_CLIENT_SECRET=` in
     `supabase/functions/.env.production` (§2.5) before Render is deleted.
   - **Same client.** A Google refresh token only works with the OAuth client that issued it.
     Use exactly the legacy client; a new client means re-consenting the mailbox and pasting a
     new refresh token in Settings.
   - Refresh tokens: the cutover moves the existing ones into Vault. For a new mailbox, get a
     refresh token with scope `https://www.googleapis.com/auth/gmail.readonly`, for example
     through the OAuth Playground using your own client after adding
     `https://developers.google.com/oauthplayground` as a redirect URI. Then paste it in
     web Settings → Sources → mailbox → Set refresh token.
5. **Watch.** `ledger-gmail-watch-renew` renews daily (watches expire after 7 days) on
   `GMAIL_PUBSUB_TOPIC`, using `sync_state.watch_label_ids` (default `["INBOX"]`). Trigger the
   first watch by hand:
   ```bash
   curl -s -X POST https://<project-ref>.supabase.co/functions/v1/gmail-watch-renew -H "x-cron-secret: $CRON_SECRET"
   ```
   The first push after a watch only stores the history cursor. Later pushes ingest.

## 6. Outlook

1. Reuse the legacy Azure app registration (personal Microsoft accounts) or create one. Grant
   delegated Graph permissions `Mail.Read` and `offline_access`, and create a client secret
   (note its expiry).
2. Set the function secrets `MS_OAUTH_CLIENT_ID` and `MS_OAUTH_CLIENT_SECRET`, plus
   `MS_OAUTH_TENANT` if not `consumers`.
3. Refresh tokens move with the cutover script. A new mailbox needs an auth-code exchange for a
   refresh token with scope `offline_access https://graph.microsoft.com/Mail.Read`, pasted in
   Settings → Sources.
4. `ledger-outlook-poll` runs hourly at :05. Run it once by hand to verify:
   `curl -X POST …/functions/v1/outlook-poll -H "x-cron-secret: $CRON_SECRET"`.

---

## 7. iOS release (TestFlight)

1. Create `apps/ios/Config/Secrets.Release.xcconfig` (gitignored):
   ```
   LEDGER_SUPABASE_URL = https:/$()/<project-ref>.supabase.co
   LEDGER_SUPABASE_ANON_KEY = <anon key>
   LEDGER_SENTRY_DSN = <ledger-apps DSN>
   ```
2. Register the App Group `group.com.example.ledger` and the keychain group (automatic signing
   does it on first archive).
3. Release:
   ```bash
   # dSYMs → ledger-apps: SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT from the environment,
   # or (when unset) from Config/Secrets.Release.xcconfig; the token is never printed.
   export ASC_KEY_ID=… ASC_ISSUER_ID=…                                 # + AuthKey_<id>.p8
   apps/ios/scripts/publish-build.sh --upload
   git add apps/ios/build-number.json && git commit …                   # the script bumps it
   ```
   - The script refuses to run without the release xcconfig, or if it points at 127.0.0.1.
   - It runs `swift test`, archives, exports, uploads dSYMs and uploads to TestFlight.
   - `--stage` stages the IPA on the `ios-ledger-staged` GitHub release instead.
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
| iOS crash-free < 99% | `ledger-apps` | Metric alert: crash-free session rate < 99% over 24 h, filtered `app:ios` (if session alerts can't filter on the tag, filter on the iOS release package `com.example.ledger`) |

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
| `ci.yml` | PRs, pushes to `main`, manual | Path-filtered jobs:<br>• `supabase`: `supabase start`, `db reset`, `test db`, DB types drift<br>• `edge`: `deno test`<br>• `parser`: ruff, pytest<br>• `web`: tokens check, lint, test, build<br>• `ios`: `swift test` on LedgerKit, macOS; only on LedgerKit/tokens changes or manual runs<br>• `scraper`<br>• legacy `backend`, `backend-security`, `frontend` |
| `deploy-supabase.yml` | **manual only** | `supabase db push` and/or `supabase functions deploy`. Requires typing the project ref to confirm. Runs in the `production` environment. |
| `deploy-parser.yml` | **manual only** | Builds `services/parser`, pushes to Artifact Registry, runs `gcloud run deploy ccs-parser` (min instances 0, secrets from Secret Manager) |
| `security.yml` | weekly, manual | pip-audit and bandit (parser); legacy pip-audit, bandit and Trivy jobs only while `LEGACY_DEPLOYS_ENABLED == 'true'` |
| `deploy-backend.yml`, `deploy-frontend.yml`, `deploy-gmail-relay.yml`, `email-ingest-microsoft.yml` | **legacy**; every job requires `LEGACY_DEPLOYS_ENABLED == 'true'` | Disable at cutover (§10 step 1), remove at decommission (step 12) |

Production deploys are never automatic.

**Guards.**
- `deploy-supabase` and `deploy-parser` run only from `main`: a `guard` job fails any dispatch
  from another ref before the `production` environment gate, and both still need their typed
  confirmation. Also give the `production` environment a deployment-branch policy of
  `main` only (Settings → Environments → production → Deployment branches).
- The legacy workflows are gated on the **repository variable** `LEGACY_DEPLOYS_ENABLED`
  (Settings → Secrets and variables → Actions → Variables). Unset or anything but `true` skips
  every legacy job, including the `email-ingest-microsoft` cron and the legacy security scans.
  `workflow_run` and `schedule` workflows always run from the default branch's copy, so the
  guard takes effect the moment `ledger-v2` is merged.

**Merge timing.** `workflow_dispatch` workflows can be dispatched only once the file is on the
default branch, so `ledger-v2` must be merged to `main` **before** the cutover day (§10, Before
the day). Merging is safe for legacy: no `backend/`, `frontend/` or `deploy/` path changes,
and the legacy workflows keep running only if `LEGACY_DEPLOYS_ENABLED` is `true`:

```bash
gh variable set LEGACY_DEPLOYS_ENABLED --body true     # BEFORE merging: keeps legacy (MS ingest cron) running
# merge ledger-v2 → main
gh variable set LEGACY_DEPLOYS_ENABLED --body false    # at cutover step 1
```

Merging also triggers any Git-connected platform that builds `main`: Render auto-deploy and
the legacy Vercel project rebuild unchanged legacy code (harmless before step 4, broken after,
so they are switched off in step 1), and the new `apps/web` Vercel project builds Production.

**Permissions.** Every workflow sets `permissions: contents: read` (or none, for the guard).
CI's `changes` job adds `pull-requests: read`, which `dorny/paths-filter` needs to list PR files
in a private repo.

**GitHub secrets.** Create a `production` environment with required reviewers.

| Secret | Used by |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | deploy-supabase (personal access token) |
| `SUPABASE_DB_PASSWORD` | deploy-supabase (`supabase link` / `db push`) |
| `SUPABASE_PROJECT_REF` | deploy-supabase, deploy-parser (`<project-ref>`) |
| `GCP_SA_KEY`, `GCP_PROJECT_ID` | deploy-parser (same pattern as the legacy gmail relay) |

The GCP deploy SA needs roles `run.admin`, `artifactregistry.writer` and
`iam.serviceAccountUser` on `ccs-parser@`.

---

## 10. Cutover runbook

Legacy and v2 share the Supabase project. The first v2 migration moves the legacy tables into
the `legacy` schema, which stops the legacy backend. Plan a quiet evening, about 2–3 hours plus
parsing time. Steps are in order; nothing is deleted until step 12.

**Before the day:**
- **Merge `ledger-v2` into `main`** so the manual deploy workflows can be dispatched (§9,
  Merge timing). First run `gh variable set LEGACY_DEPLOYS_ENABLED --body true`, so the legacy
  MS ingest cron keeps running until step 1. Create the `production` environment (required
  reviewers, deployment branch `main`) and its secrets (§9).
- Parser deployed and healthy (§3). Copy the URL the deploy printed into `PARSER_URL=` in
  `supabase/functions/.env.production`.
- Copy the Gmail OAuth client from Render (`CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID` / `_SECRET`) into
  `GMAIL_OAUTH_CLIENT_ID` / `GMAIL_OAUTH_CLIENT_SECRET` in the same file (§5.4), and add the other
  missing keys from the §2.5 table. Only `MS_OAUTH_*` may stay missing (step 7 adds them).
  `scripts/cutover/set-edge-secrets.sh --dry-run --sentry-release "$(git rev-parse --short HEAD)"`
  must pass.
- New Vercel project building `apps/web` with the env vars from `apps/web/.env.production.local`
  (§4).
- Sentry projects created (§8).
- **Rotate the secrets that were exposed** in chat transcripts or logs during development: the
  Anthropic API key (Anthropic console → new key → `ANTHROPIC_API_KEY=` in
  `supabase/functions/.env.production`, revoke the old one) and the Sentry org auth token
  (Sentry → Settings → Auth Tokens → new token → Vercel `SENTRY_AUTH_TOKEN` and your shell for
  `publish-build.sh`, revoke the old one).
- Dashboard: **sign-ups off** (§2.2, §2.7).
- Both members' emails confirmed: **`h_abbasi97@hotmail.com`** owns profile `alice` and
  **`bob@example.com`** owns profile `bob`. With sign-ups off they get in by
  Auth invite after step 7 (§2.2).
- **Rehearse steps 4–8 end to end with the final code** on the local stack loaded from a fresh
  prod backup (`--target local`, as in docs/audit/02): all migrations from scratch, then
  metadata, secrets, pdfs, drain, the post-import checks and finalize. Sign-off criterion:
  `legacy_lines_missing = 0` for every bank and only the expected monthly deltas (step 8).
  - **Start every rehearsal from `supabase db reset`** (or a fresh stack), never from a stack
    that already applied some versions. `supabase migration up` matches migrations by version
    only, so a migration edited after it was applied is silently skipped and the rehearsal tests
    stale SQL (docs/audit/07 FV-04). Prod is unaffected as long as no v2 version has been pushed.
  - To rehearse against production's grants, emulate its legacy default privileges first
    (`alter default privileges for role postgres in schema public grant all on tables to anon,
    authenticated`, and the same `on sequences`, as a migration sorted before `…0000`; see
    docs/audit/07 FV-01) or load the prod schema dump; `supabase test db`
    must pass there too (`11_privileges` pins the client privilege matrix).
- Local tools ready (quote the extra in zsh):
  ```bash
  backend/.venv/bin/pip install 'psycopg[binary]' httpx cryptography google-cloud-storage
  ```
- Legacy values at hand: a read-capable SA key for the GCS bucket (`GOOGLE_APPLICATION_CREDENTIALS`).
  The Fernet key and bucket name are already in `.env.cutover`.

**Local secret files (all gitignored, mode 600; values never go in the repo or the shell
history):**

| File | Holds | Used in |
|---|---|---|
| `supabase/functions/.env.production` | `CRON_SECRET`, `PARSER_SECRET`, `ANTHROPIC_API_KEY`, `LLM_MODEL`, `SENTRY_DSN`, `SENTRY_ENVIRONMENT`; **placeholders** `PARSER_URL`, `SENTRY_RELEASE` | single source for function secrets and Vault `edge_cron_secret` (§2.4, §2.5; steps 5–7) |
| `services/parser/.env.production` | `PARSER_SECRET` (same value as above), `PARSER_ALLOWED_HOSTS`, `SENTRY_DSN`, `SENTRY_ENVIRONMENT` | Secret Manager `parser-secret` / `parser-sentry-dsn` (§3). Never uploaded (`.gcloudignore`) |
| `apps/web/.env.production.local` | `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_SENTRY_DSN`, `VITE_SENTRY_ENVIRONMENT`, `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT` | Vercel env (§4) |
| `apps/ios/Config/Secrets.Release.xcconfig` | `LEDGER_SUPABASE_URL`, `LEDGER_SUPABASE_ANON_KEY`, `LEDGER_SENTRY_DSN`, `LEDGER_ENVIRONMENT`; optionally `SENTRY_AUTH_TOKEN`/`SENTRY_ORG`/`SENTRY_PROJECT`, which `publish-build.sh` uses for dSYMs when the shell doesn't set them (prefer the shell: in the xcconfig the token is also an Xcode build setting, BACKLOG IOS-21) | TestFlight builds (§7) |
| `.env.cutover` (repo root) | `LEGACY_FERNET_KEY`, `LEGACY_STORAGE`, `LEGACY_GCS_BUCKET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, Sentry org token and DSNs, `GCP_PROJECT=<gcp-project>`, `GCP_REGION=me-central1` (not the parser's region); **placeholder** `LEDGER_DB_URL` | steps 2 and 7. Fill `LEDGER_DB_URL` (session pooler, port 5432, Dashboard → Connect) before the day |

At the start of the session:

```bash
set -a; source .env.cutover; set +a                  # LEDGER_DB_URL, SUPABASE_*, LEGACY_*
export LEGACY_DB_URL="$LEDGER_DB_URL"                # same database: legacy and v2 share the project
export CRON_SECRET="$(grep '^CRON_SECRET=' supabase/functions/.env.production | cut -d= -f2-)"
```

### Steps

1. **Freeze legacy.** In this order: stop the things that write, then the things that build.
   1. **GitHub Actions.** Turn off every legacy workflow (the variable guards them; disabling
      is belt and braces):
      ```bash
      gh variable set LEGACY_DEPLOYS_ENABLED --body false
      for w in email-ingest-microsoft.yml deploy-backend.yml deploy-frontend.yml deploy-gmail-relay.yml; do
        gh workflow disable "$w"
      done
      ```
      `email-ingest-microsoft` is the daily MS ingest cron. The three `deploy-*` workflows fire
      on `workflow_run` after any green CI on `main`. The `security.yml` legacy jobs stop with
      the variable.
   2. **Render** (`ccs-platform`, the API and embedded worker): Settings → Build & Deploy →
      **Auto-Deploy: off** first, so no later `main` commit rebuilds it (and a rollback resume
      doesn't build new code), then **Suspend** the service.
   3. **Legacy Vercel project** (root `frontend/`): Settings → Git → **disconnect** the repo (or
      set Ignored Build Step to `exit 0`). It keeps serving the production domain until step 9.
   4. **Cloud Scheduler** `ccs-gmail-watch-renew`: pause it
      (`gcloud scheduler jobs pause ccs-gmail-watch-renew --project <gcp-project> --location <region>`;
      `gcloud scheduler jobs list` shows the region).
   5. **Cloud Run relay** `ccs-gmail-relay`: leave it deployed. Its target API is suspended, so
      Gmail notifications fail and Pub/Sub retries them until step 11. Optionally detach the
      push endpoint (`--push-endpoint=""`) so they queue instead.
   6. **Scraper:** don't run it, and unload any cron/launchd job you set up for `ccs-scraper`
      (none is defined in this repo).
2. **Back up.**
   ```bash
   pg_dump "$LEGACY_DB_URL" -Fc -f legacy-$(date +%F).dump        # whole DB (session pooler, port 5432)
   pg_dump "$LEGACY_DB_URL" --schema=public --data-only -Fc -f legacy-public-data-$(date +%F).dump
   gsutil ls -l -r "gs://$LEGACY_GCS_BUCKET" > gcs-listing-$(date +%F).txt
   ```
   - Keep the dumps and listing off-machine.
   - Record the legacy row counts (`statements`, `statement_lines`, `pdf_files`) for comparison.
3. **Upgrade Postgres** (§2.1, §2.7). Wait until the project is healthy.
4. **Apply v2 migrations.** `supabase migration list --linked` (expect only local versions,
   all pending), `supabase db push --dry-run`, then `supabase db push`. Or run the Deploy
   Supabase workflow from `main` with `db_push = true`.
   - Verify `select count(*) from legacy.statements;` matches the backup.
   - Verify `public` now holds the v2 tables.
   - Dashboard → Data API → **Max rows = 2000** (§2.7).
5. **Push function secrets and deploy the functions.**
   ```bash
   scripts/cutover/set-edge-secrets.sh --sentry-release "$(git rev-parse --short HEAD)"
   supabase functions deploy --project-ref <project-ref>   # or Deploy Supabase, deploy_functions only
   ```
   - The script refuses placeholders, so `PARSER_URL` must already be the real Cloud Run URL.
   - Smoke test (§2.5): parser `/health` responds; `worker` returns 401 without the header and
     a summary with `x-cron-secret: $CRON_SECRET`.
6. **Set Vault** `project_url` and `edge_cron_secret` from the same `CRON_SECRET` (§2.4). This
   switches pg_cron → Edge on. From here:
   - `ledger-outlook-poll` reports `MISCONFIGURED` hourly until step 7 pushes the MS keys
     (expected Sentry noise), then starts ingesting before step 11. Dedup makes that safe.
   - `ledger-gmail-watch-renew` (03:00 UTC) renews the watch on the same topic; the push
     subscription still targets the relay until step 11.
7. **Migrate data** with `scripts/migrate_legacy.py`. Every call names its target:
   `--target prod` checks that `LEDGER_DB_URL` and `SUPABASE_URL` both name
   `<project-ref>` (pooler user or `db.<ref>` host) and refuses otherwise. A dry run is
   the default. A prod write also needs `--yes-i-mean-prod <project-ref>` (or typing the
   ref at the prompt). Run each step **dry first**, read the output, then apply.
   ```bash
   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/legacy-reader.json   # the rest came from .env.cutover
   M='{"alice":"h_abbasi97@hotmail.com","bob":"bob@example.com"}'
   ml() { backend/.venv/bin/python scripts/migrate_legacy.py --target prod "$@"; }   # works in zsh and bash
   YES=<project-ref>

   ml --step metadata --members "$M"                                   # dry run
   ml --step metadata --members "$M" --apply --yes-i-mean-prod "$YES"
   ml --step secrets                                                   # dry run
   ml --step secrets --apply --yes-i-mean-prod "$YES" --functions-env-out supabase/functions/.env.production
   scripts/cutover/set-edge-secrets.sh --sentry-release "$(git rev-parse --short HEAD)"   # push MS_OAUTH_*
   ml --step pdfs --limit 3                                            # dry run (downloads to hash; slow, read-only)
   ml --step pdfs --limit 3 --apply --yes-i-mean-prod "$YES"           # canary: watch them parse
   ml --step pdfs --apply --yes-i-mean-prod "$YES"
   ```
   - **metadata** imports profiles, legacy-only categories, user rules, staged category choices
     and email mailboxes and routes. Members who haven't signed up are stored as pending
     invites and claimed at sign-up.
   - **secrets** moves PDF passwords and mailbox refresh tokens into Vault. It finds only the
     **MS** OAuth client in the legacy DB and merges `MS_OAUTH_CLIENT_ID/SECRET` into
     `supabase/functions/.env.production`, replacing just those lines. Push with
     `set-edge-secrets.sh` as above, **not** the `supabase secrets set --env-file` hint the
     script prints, and keep the file (it is the source of truth until step 12). The Gmail
     client is not in the DB; it came from Render before the day (§5.4).
   - **pdfs** uploads every legacy PDF into Storage as `documents(source='legacy')`, with
     `bank_code` set from legacy when all of a PDF's legacy statements agree (so parsing doesn't
     rely on bank detection). The worker re-parses them through the v2 pipeline. Upload order no
     longer matters: ingest serialises per profile and unions lines across documents
     (ARCHITECTURE §4), so a card-less ADCB companion PDF or a shorter SIB history window can't
     drop lines whichever finishes last. An insert conflict deletes the just-uploaded object.
   - **Invite the members** once metadata has stored their pending invites: Dashboard →
     Authentication → Users → **Invite user** for each email (§2.2). They can sign in from
     step 9.
8. **Wait for the worker to drain.**
   ```sql
   select parse_status, count(*) from public.documents group by 1;   -- until no queued/parsing
   ```
   ```sql
   select queue_name, queue_length from pgmq.metrics_all();
   ```
   - Investigate `failed` documents (`parse_error_code`). Fix the password in Settings, then
     `select requeue_documents('<prf_…>', array['doc_…'])` as an owner, or update and requeue
     via SQL.
   - **Post-import checks (ENBD and FAB).** The parser now re-derives ENBD/EIB years at the
     Dec/Jan boundary and reads FAB rows with `EUR 108,99` / `KWD 18.750` amounts. A document
     parsed by an older parser revision (for example a canary before the parser redeploy) keeps
     the old result until it is re-parsed. In a clean run the parser is deployed before the day,
     so these checks should come back empty. Check, as `postgres` in psql:
     ```sql
     -- 1. Statements with an impossible date (expect 0 rows): a future statement date,
     --    a period over 100 days, or a due date before the statement date.
     select a.profile_code, a.bank_code, s.stmt_code, s.doc_code, s.statement_date,
            s.period_start, s.period_end, s.due_date, d.parser_version
     from public.statements s
     join public.accounts a on a.profile_code = s.profile_code and a.account_code = s.account_code
     left join public.documents d on d.profile_code = s.profile_code and d.doc_code = s.doc_code
     where s.status = 'active' and s.kind = 'statement'
       and (s.statement_date > current_date + 31
            or s.period_end - s.period_start > 100
            or s.due_date < s.statement_date);

     -- 2. ENBD/EIB/FAB documents parsed before the current parser revision went live
     --    (PARSER_VERSION was not bumped for these fixes, so compare parsed_at with the
     --    time of the last parser deploy), and any failed ones.
     select profile_code, bank_code, parse_status, parse_error_code,
            count(*) filter (where parsed_at < '<last parser deploy, UTC>') as parsed_before_deploy,
            count(*) as total
     from public.documents
     where bank_code in ('ENBD', 'EIB', 'FAB')
     group by 1, 2, 3, 4 order by 1, 2;

     -- 3. FAB statements that still don't reconcile (expect none from DP-07; FAB credit-total
     --    extraction can still give a few false 'fail's, BACKLOG DP-10).
     select r.status, count(*) from public.statement_recon r
     join public.statements s on s.stmt_code = r.stmt_code
     join public.accounts a on a.profile_code = s.profile_code and a.account_code = s.account_code
     where a.bank_code = 'FAB' and s.status = 'active' group by 1;
     ```
     If (1) or (2) finds anything, re-parse those documents. `requeue_documents` runs as
     `postgres` (the RPC guard lets non-JWT sessions through):
     ```sql
     select public.requeue_documents(profile_code, array_agg(doc_code))
     from public.documents
     where bank_code in ('ENBD', 'EIB', 'FAB') and parsed_at < '<last parser deploy, UTC>'
     group by profile_code;
     ```
     A re-parse that now produces `2025-12-28` instead of `2026-12-28` withdraws its evidence
     from the bad-year statement, which is retired automatically (`superseded`, ARCHITECTURE
     §4). If a bad-year statement is still `active` afterwards (it came from a different
     document), supersede it through one of the `period_overlap` reviews that names it, then
     dismiss the remaining overlap reviews it caused:
     ```sql
     -- find the reviews that list the stale statement as a candidate
     select review_code, subject_code from public.match_reviews
     where status = 'open' and reason = 'period_overlap'
       and candidates @> jsonb_build_array(jsonb_build_object('stmt_code', '<stm_stale>'));
     select public.resolve_review('<rev_one_of_them>', jsonb_build_object('supersede', '<stm_stale>'));
     select public.resolve_review('<rev_each_other>', '{"dismiss": true}'::jsonb);
     ```
     Re-run query (1) until it is empty, and wait for the worker to drain again.
   - Then finalize:
     ```bash
     ml --step finalize                                    # dry run: read the parity report
     ml --step finalize --apply --yes-i-mean-prod "$YES"   # apply staged legacy category choices
     ```
   - **Parity sign-off.** The report prints, per profile and bank, `months_with_delta`,
     `legacy_lines_missing` and `legacy_aed_missing`.
     - `legacy_lines_missing` must be **0** for every bank. Otherwise list the lines with
       `select * from private.legacy_missing_lines();` and stop.
     - Monthly AED deltas must be explained only by known differences (docs/audit/02): the
       legacy phantom copy of the ENBD Dec-2025 statement (v2 keeps one copy); refunds netted
       against spend; debits in income/transfer categories excluded from spend (e.g.
       `MURABAHA PROFIT` → Cashback, BACKLOG DP-09); lines legacy never had (SIB history PDFs it
       never parsed, the recovered FAB EUR/KWD rows); and AED estimates on null-AED FX lines.
     - `select * from private.legacy_unmatched_choices();` lists staged category choices that
       met no line (expected: the phantom ENBD lines and a few legacy typo categories).

     Anything else blocks the rest of the cutover.
9. **Switch the web app.** Promote the `apps/web` Vercel project to the production domain and
   remove the domain from the legacy project. Update Auth → URL Configuration (§2.2). Sign in
   as both members (from the step 7 invites) and check Overview, Activity and Cards & Statements
   against legacy numbers. Sign-ups stay off (§2.7).
10. **Point the scraper at v2** (in `scraper/.env`):
    ```dotenv
    CCS_SCRAPER_TARGET_URL=https://<project-ref>.supabase.co
    CCS_SCRAPER_UPLOAD_PATH=/functions/v1/statements-upload
    CCS_SCRAPER_SUPABASE_ANON_KEY=<anon key>
    ALICE_CCS_SCRAPER_API_TOKEN=ccs_…    # new v2 tokens, scope statements:upload,
    BOB_CCS_SCRAPER_API_TOKEN=ccs_…   # one per profile
    ```
    - v2 tokens belong to one profile. Create one per profile in Settings → Sources → Tokens.
      `--profile <name>` picks `<NAME>_CCS_SCRAPER_API_TOKEN`, falling back to the global
      `CCS_SCRAPER_API_TOKEN` (remove the legacy global token so a missing profile token fails
      fast instead of uploading with the wrong one).
    - Run `ccs-scraper upload-pending --profile alice` to confirm the upload path. Already
      imported PDFs return `duplicate`.
11. **Switch email.**
    - Gmail: repoint the push subscription to `gmail-push` (§5, item 3), run `gmail-watch-renew` once,
      then send yourself a test statement email and check `public.email_events`.
    - Outlook: run `outlook-poll` once and check the mailbox `last_synced_at`.
    - **Verify:**
      - `ops-monitor` returns no issues.
      - `ops-heartbeat` is checking in.
      - Sentry shows no new errors.
      - A test SMS from each phone appears live.
      - `statement_recon` shows no unexpected `fail`.
12. **Keep legacy read-only for 30 days, then decommission.** Until then the `legacy` schema
    stays untouched (no client role can read it) and Render stays suspended, not deleted.
    After 30 clean days:
    - Delete the Render service, the legacy Vercel project, the Cloud Run `ccs-gmail-relay`
      service and its Cloud Scheduler job, and the GCS bucket. Export the bucket first if you
      want a cold copy.
    - Delete the workflows `deploy-backend.yml`, `deploy-frontend.yml`, `deploy-gmail-relay.yml`
      and `email-ingest-microsoft.yml`, the legacy CI jobs (`backend`, `backend-security`,
      `frontend` and their `changes` filters) and the `security.yml` `python`/`container` jobs,
      then `gh variable delete LEGACY_DEPLOYS_ENABLED`. The git hooks skip `backend/` and
      `frontend/` once they are gone.
    - Delete `backend/`, `frontend/`, `deploy/Dockerfile.api`, `deploy/Dockerfile.frontend`,
      `deploy/Dockerfile.gmail-relay` and the legacy `docs/operations` and `docs/security`
      notes.
    - Optionally `select cron.unschedule('ledger-legacy-choices')` (in a migration).
    - Shred the cutover-only secret files: `rm -P .env.cutover` and the legacy reader SA key.
      Keep `supabase/functions/.env.production` (or move it to a password manager) for future
      rotations; it is the only place `CRON_SECRET` is readable.
    - Dropping the `legacy` schema is a separate, explicit decision. Take a final `pg_dump`
      first.

### Rollback

| Failure point | Rollback |
|---|---|
| Before step 4 | Undo step 1 in reverse: reconnect the legacy Vercel project's Git (if wanted), resume the scheduler job, resume Render (leave Auto-Deploy off unless you need it), then `gh variable set LEGACY_DEPLOYS_ENABLED --body true` and `gh workflow enable` the four legacy workflows. Nothing changed. |
| Steps 4–8 (v2 schema applied, parity not signed off) | Stop the v2 cron by deleting the Vault secret `edge_cron_secret`, which makes `invoke_edge` skip, or unschedule `ledger-worker-kick`. Move the legacy tables back: in one transaction, `alter table legacy.<t> set schema public` and `alter type legacy.<type> set schema public` for every table and enum listed in `20261008000000_quarantine_legacy.sql`. Rename or drop the clashing v2 tables first; `profiles`, `banks`, `categories`, `category_rules`, `statements`, `statement_lines`, `email_mailboxes` and `audit_events` share names. As a last resort, restore `legacy-<date>.dump` into a fresh project. Then undo step 1 as in the row above and repoint nothing (no external endpoints were switched yet). |
| Steps 9–11 | Point the Vercel domain back at the legacy project, restore the Pub/Sub push endpoint to the legacy relay URL, set the scraper back to `CCS_SCRAPER_UPLOAD_PATH=/api/v1/jobs/upload` and the Render URL, then follow the row above. |
| After step 12 | No rollback to legacy. Restore from the final dump if ever needed. |

Uploads and SMS ingested by v2 during a rollback window stay in v2 and will re-appear when you
cut over again. sha256 and `client_msg_id` dedup make re-sending them safe.

---

## 11. Operations

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
