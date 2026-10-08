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
| Database, Auth, Storage, Edge Functions, Realtime, Vault, pg_cron, pgmq | Supabase Free | project **`cc-statement-scraper`**, ref **`nkmylznisjcnmqbxosey`** (the same project legacy uses) |
| Statement parser | GCP Cloud Run | service `ccs-parser`, region `europe-west1`, min instances 0 |
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
- **Sign-ups.** Members must be able to sign up to claim their invite: `add_profile_member`
  stores pending invites by email, and sign-up attaches them. Leave email sign-ups on until both
  members exist, then optionally disable them. RLS isolates any stray account anyway.
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

Run these once in the SQL editor. Values never go in migrations.

```sql
select vault.create_secret('https://nkmylznisjcnmqbxosey.supabase.co', 'project_url');
select vault.create_secret('<CRON_SECRET>', 'edge_cron_secret');   -- same value as the CRON_SECRET function secret
-- to change later: select vault.update_secret(id, '<new>') from vault.secrets where name = 'edge_cron_secret';
```

Per-profile and per-mailbox secrets are written through RPCs, never by hand:

| Vault name | Written by | Read by |
|---|---|---|
| `profile:<prf_…>:FAB_PDF_PASSWORD` … `MASHREQ_PDF_PASSWORD`, `ADCB_CID` | web Settings → PDF passwords (`set_profile_secret`), or `migrate_legacy.py --step secrets` | worker → parser `settings` |
| `mailbox:<mbx_…>:refresh_token` | web Settings → Sources → mailbox → Set refresh token (`set_mailbox_secret`), or the cutover script | gmail-push, gmail-watch-renew, outlook-poll |

### 2.5 Edge Functions

Function secrets (`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are
injected automatically):

```bash
supabase secrets set --project-ref nkmylznisjcnmqbxosey \
  CRON_SECRET="$(openssl rand -hex 32)" \
  PARSER_URL=https://ccs-parser-<hash>-ew.a.run.app \
  PARSER_SECRET=<same value as the parser-secret Secret Manager secret> \
  ANTHROPIC_API_KEY=<key> \
  GMAIL_PUSH_AUDIENCE=https://nkmylznisjcnmqbxosey.supabase.co/functions/v1/gmail-push \
  GMAIL_PUSH_SA_EMAIL=ccs-gmail-push@<gcp-project>.iam.gserviceaccount.com \
  GMAIL_PUBSUB_TOPIC=projects/<gcp-project>/topics/ccs-gmail-push \
  GMAIL_OAUTH_CLIENT_ID=<google oauth client id> GMAIL_OAUTH_CLIENT_SECRET=<secret> \
  MS_OAUTH_CLIENT_ID=<azure client id> MS_OAUTH_CLIENT_SECRET=<secret> \
  ALLOWED_ORIGINS=https://<vercel-domain> \
  SENTRY_DSN=<ledger-backend DSN> SENTRY_ENVIRONMENT=production SENTRY_RELEASE=$(git rev-parse --short HEAD)
supabase secrets list --project-ref nkmylznisjcnmqbxosey
```

- Use the `CRON_SECRET` value you put in Vault as `edge_cron_secret`.
- Optional overrides: `LLM_MODEL`, `MS_OAUTH_TENANT` (`consumers`), `OUTLOOK_LOOKBACK_DAYS`,
  `OUTLOOK_BUDGET_MS`, `WORKER_BUDGET_MS`, `PARSER_TIMEOUT_MS`,
  `OPS_SMS_UNPARSED_THRESHOLD`, `OPS_OPEN_REVIEWS_THRESHOLD` and `SENTRY_TRACES_SAMPLE_RATE`
  (see README).
- **Never set `PARSER_DOCUMENT_BASE_URL` in production.** It exists for local Docker only.

Deploy every function. Each one's `verify_jwt = false` comes from `supabase/config.toml`:

```bash
supabase functions deploy --project-ref nkmylznisjcnmqbxosey
# statements-upload sms-ingest worker gmail-push gmail-watch-renew outlook-poll ops-monitor fx-rates
```

Smoke test:

```bash
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
| `ledger-legacy-choices` | `45 22 * * *` | re-apply staged legacy category choices (cutover helper; idempotent) |
| `ledger-ops-monitor` | `*/15 * * * *` | `ops-monitor` → Sentry plus the `ops-heartbeat` check-in |
| `ledger-gmail-watch-renew` | `0 3 * * *` | `gmail-watch-renew` |
| `ledger-outlook-poll` | `5 * * * *` | `outlook-poll` |

Check job health with `select jobname, schedule, active from cron.job;` and
`select * from cron.job_run_details order by start_time desc limit 20;`. Once v2 parity is
signed off and every staged choice has applied, unschedule the legacy helper with
`select cron.unschedule('ledger-legacy-choices')`. Do this in a new migration.

---

## 3. Parser on Cloud Run

From `services/parser/README.md`, with legacy GCP conventions (project from
`GCP_PROJECT_ID`, Artifact Registry repo `ccs-platform` in `europe-west1`).

```bash
PROJECT=<gcp-project>; REGION=europe-west1; SERVICE=ccs-parser

# One time: secrets in Secret Manager and a least-privilege service account
printf '%s' "$(openssl rand -hex 32)" | gcloud secrets create parser-secret --data-file=- --project "$PROJECT"
printf '%s' "<ledger-backend DSN>"    | gcloud secrets create parser-sentry-dsn --data-file=- --project "$PROJECT"
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
curl -s "$(gcloud run services describe $SERVICE --region $REGION --format 'value(status.url)')/health"
```

- `--allow-unauthenticated` is required. The worker authenticates with `X-Parser-Secret`, not a
  Google identity token. `PARSER_ALLOWED_HOSTS` limits downloads to the project's Storage.
- After deploying, set the service URL as `PARSER_URL` and the `parser-secret` value as
  `PARSER_SECRET` in the function secrets (§2.5).
- To rotate the secret: add a new secret version, redeploy the parser, then
  `supabase secrets set PARSER_SECRET=…`. Parses fail as *transient* in between and retry.
- The **Deploy Parser** workflow (§9) builds the image with `services/parser/Dockerfile`, pushes
  it to Artifact Registry and runs the same `gcloud run deploy`.

---

## 4. Web on Vercel

| Setting | Value |
|---|---|
| Root Directory | `apps/web` (enable "Include files outside the root directory", since it uses workspace packages) |
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
     --push-endpoint=https://nkmylznisjcnmqbxosey.supabase.co/functions/v1/gmail-push \
     --push-auth-service-account=ccs-gmail-push@$PROJECT.iam.gserviceaccount.com \
     --push-auth-token-audience=https://nkmylznisjcnmqbxosey.supabase.co/functions/v1/gmail-push
   gcloud pubsub subscriptions update ccs-gmail-push-sub --ack-deadline=120 --project $PROJECT
   ```
   For a fresh setup, use `subscriptions create … --topic ccs-gmail-push` with the same flags.
4. **OAuth client.**
   - Function secrets: `GMAIL_OAUTH_CLIENT_ID` and `GMAIL_OAUTH_CLIENT_SECRET`.
   - Refresh tokens: the cutover moves the existing ones into Vault. For a new mailbox, get a
     refresh token with scope `https://www.googleapis.com/auth/gmail.readonly`, for example
     through the OAuth Playground using your own client after adding
     `https://developers.google.com/oauthplayground` as a redirect URI. Then paste it in
     web Settings → Sources → mailbox → Set refresh token.
5. **Watch.** `ledger-gmail-watch-renew` renews daily (watches expire after 7 days) on
   `GMAIL_PUBSUB_TOPIC`, using `sync_state.watch_label_ids` (default `["INBOX"]`). Trigger the
   first watch by hand:
   ```bash
   curl -s -X POST https://nkmylznisjcnmqbxosey.supabase.co/functions/v1/gmail-watch-renew -H "x-cron-secret: $CRON_SECRET"
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
   LEDGER_SUPABASE_URL = https:/$()/nkmylznisjcnmqbxosey.supabase.co
   LEDGER_SUPABASE_ANON_KEY = <anon key>
   LEDGER_SENTRY_DSN = <ledger-apps DSN>
   ```
2. Register the App Group `group.com.hussu97.ledger` and the keychain group (automatic signing
   does it on first archive).
3. Release:
   ```bash
   export SENTRY_AUTH_TOKEN=… SENTRY_ORG=… SENTRY_PROJECT=ledger-apps   # dSYMs → ledger-apps
   export ASC_KEY_ID=… ASC_ISSUER_ID=…                                 # + AuthKey_<id>.p8
   apps/ios/scripts/publish-build.sh --upload
   git add apps/ios/build-number.json && git commit …                   # the script bumps it
   ```
   - The script refuses to run without the release xcconfig, or if it points at 127.0.0.1.
   - It runs `swift test`, archives, exports, uploads dSYMs and uploads to TestFlight.
   - `--stage` stages the IPA on the `ios-ledger-staged` GitHub release instead.
4. On each phone, after installing from TestFlight:
   - Sign in.
   - Settings → *Set up SMS capture*: create the "Message contains …" automations with **Run
     Immediately**.
   - Send yourself a test bank-format SMS and confirm a pending transaction appears on the web
     app.

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

**Alerts:**

| Alert | Project | Rule |
|---|---|---|
| New issue | both | Issue alert: "A new issue is created", `environment:production`, notify by email |
| Ops heartbeat | `ledger-backend` | Cron monitor `ops-heartbeat`, auto-created by the first check-in (`*/15 * * * *`, 5 min margin), alert on missed or failed check-in |
| DLQ > 0 | `ledger-backend` | Issue alert: event tag `ops_issue` starts with `dlq:` (from `ops-monitor`), plus worker DLQ error events, any frequency |
| iOS crash-free < 99% | `ledger-apps` | Metric alert: crash-free session rate < 99% over 24 h, filtered `app:ios` (if session alerts can't filter on the tag, filter on the iOS release package `com.hussu97.ledger`) |

Non-production debug triggers to verify delivery:
- Edge: the `?debug_sentry=1` flag.
- Parser: `GET /debug-sentry`, with `X-Parser-Secret`.
- iOS: the Settings → Debug section.
- Web: no trigger yet (ROADMAP).

---

## 9. CI/CD (GitHub Actions)

| Workflow | Trigger | What |
|---|---|---|
| `ci.yml` | PRs, pushes to `main`, manual | Path-filtered jobs:<br>• `supabase`: `supabase start`, `db reset`, `test db`, DB types drift<br>• `edge`: `deno test`<br>• `parser`: ruff, pytest<br>• `web`: tokens check, lint, test, build<br>• `ios`: `swift test` on LedgerKit, macOS; only on LedgerKit/tokens changes or manual runs<br>• `scraper`<br>• legacy `backend`, `backend-security`, `frontend` |
| `deploy-supabase.yml` | **manual only** | `supabase db push` and/or `supabase functions deploy`. Requires typing the project ref to confirm. Runs in the `production` environment. |
| `deploy-parser.yml` | **manual only** | Builds `services/parser`, pushes to Artifact Registry, runs `gcloud run deploy ccs-parser` (min instances 0, secrets from Secret Manager) |
| `security.yml` | weekly, manual | pip-audit (legacy backend and parser), bandit, Trivy (legacy image) |
| `deploy-backend.yml`, `deploy-frontend.yml`, `deploy-gmail-relay.yml`, `email-ingest-microsoft.yml` | **legacy** | Remove at decommission (§10, step 12) |

Production deploys are never automatic.

**GitHub secrets.** Create a `production` environment with required reviewers.

| Secret | Used by |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | deploy-supabase (personal access token) |
| `SUPABASE_DB_PASSWORD` | deploy-supabase (`supabase link` / `db push`) |
| `SUPABASE_PROJECT_REF` | deploy-supabase, deploy-parser (`nkmylznisjcnmqbxosey`) |
| `GCP_SA_KEY`, `GCP_PROJECT_ID` | deploy-parser (same pattern as the legacy gmail relay) |

The GCP deploy SA needs roles `run.admin`, `artifactregistry.writer` and
`iam.serviceAccountUser` on `ccs-parser@`.

---

## 10. Cutover runbook

Legacy and v2 share the Supabase project. The first v2 migration moves the legacy tables into
the `legacy` schema, which stops the legacy backend. Plan a quiet evening, about 2–3 hours plus
parsing time. Steps are in order; nothing is deleted until step 12.

**Before the day:**
- Parser deployed and healthy (§3); new Vercel project building `apps/web` (§4, with
  `vercel.json`).
- Sentry projects created (§8).
- Both members' emails confirmed: **`h_abbasi97@hotmail.com`** owns profile `hussain` and
  **`tejasvie.vemuri@gmail.com`** owns profile `tejasvie`.
- Local tools ready:
  ```bash
  backend/.venv/bin/pip install psycopg[binary] httpx cryptography google-cloud-storage
  ```
- Legacy values at hand: the Fernet key (`CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY` from
  Render), the GCS bucket name and a read-capable SA key.

### Steps

1. **Freeze legacy.**
   - Render: suspend the `ccs-platform` web service, which runs the API and embedded worker.
   - Disable the `email-ingest-microsoft` workflow (`gh workflow disable email-ingest-microsoft.yml`).
   - Pause the Cloud Scheduler job `ccs-gmail-watch-renew`.
   - Don't run the scraper.
   - Gmail notifications keep queueing in Pub/Sub, which retries them. Optionally detach the
     push endpoint so they wait.
2. **Back up.**
   ```bash
   pg_dump "$LEGACY_DB_URL" -Fc -f legacy-$(date +%F).dump        # whole DB (session pooler, port 5432)
   pg_dump "$LEGACY_DB_URL" --schema=public --data-only -Fc -f legacy-public-data-$(date +%F).dump
   gsutil ls -l -r gs://<legacy-bucket> > gcs-listing-$(date +%F).txt
   ```
   - Keep the dumps and listing off-machine.
   - Record the legacy row counts (`statements`, `statement_lines`, `pdf_files`) for comparison.
3. **Upgrade Postgres** (§2.1, recommended). Wait until the project is healthy.
4. **Apply v2 migrations.** `supabase db push --dry-run`, then `supabase db push`. Or run the
   Deploy Supabase workflow with `db_push = true`.
   - Verify `select count(*) from legacy.statements;` matches the backup.
   - Verify `public` now holds the v2 tables.
5. **Set Vault and secrets.**
   - Vault `project_url` and `edge_cron_secret` (§2.4).
   - All function secrets (§2.5) except the Gmail and MS OAuth client values, which come from
     step 7.
6. **Deploy Edge Functions** (§2.5) and confirm that the parser `/health` responds and that the
   `worker` smoke test returns a summary.
7. **Migrate data** with `scripts/migrate_legacy.py`. Run each step dry first, then `--apply`.
   ```bash
   export LEDGER_DB_URL=postgresql://postgres.nkmylznisjcnmqbxosey:<pw>@aws-0-<region>.pooler.supabase.com:5432/postgres
   export SUPABASE_URL=https://nkmylznisjcnmqbxosey.supabase.co SUPABASE_SERVICE_ROLE_KEY=<service role key>
   export LEGACY_FERNET_KEY=<legacy runtime settings key> LEGACY_STORAGE=gcs LEGACY_GCS_BUCKET=<bucket> \
          GOOGLE_APPLICATION_CREDENTIALS=/path/to/legacy-reader.json
   M='{"hussain":"h_abbasi97@hotmail.com","tejasvie":"tejasvie.vemuri@gmail.com"}'

   backend/.venv/bin/python scripts/migrate_legacy.py --step metadata --members "$M"            # dry run
   backend/.venv/bin/python scripts/migrate_legacy.py --step metadata --members "$M" --apply
   backend/.venv/bin/python scripts/migrate_legacy.py --step secrets                           # dry run
   backend/.venv/bin/python scripts/migrate_legacy.py --step secrets --apply --functions-env-out supabase/functions/.env.production
   backend/.venv/bin/python scripts/migrate_legacy.py --step pdfs --limit 3 --apply             # canary: watch them parse
   backend/.venv/bin/python scripts/migrate_legacy.py --step pdfs --apply
   ```
   - **metadata** imports profiles, legacy-only categories, user rules, staged category choices
     and email mailboxes and routes. Members who haven't signed up are stored as pending
     invites and claimed at sign-up.
   - **secrets** moves PDF passwords and mailbox refresh tokens into Vault, and writes the
     OAuth app credentials to the env file. That file is gitignored by the root `.env.*`
     rule; delete it after use. The names it writes (`GMAIL_OAUTH_CLIENT_ID/SECRET`,
     `MS_OAUTH_CLIENT_ID/SECRET`) are exactly the ones the functions read, so push it as-is with
     `supabase secrets set --env-file supabase/functions/.env.production`.
   - **pdfs** uploads every legacy PDF into Storage as `documents(source='legacy')`. Real
     statements go first, oldest first, and SIB history extracts last. The worker re-parses
     them through the v2 pipeline.
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
   - Then finalize:
     ```bash
     backend/.venv/bin/python scripts/migrate_legacy.py --step finalize           # read the parity report
     backend/.venv/bin/python scripts/migrate_legacy.py --step finalize --apply   # apply staged legacy category choices
     ```
   - **Parity sign-off.** Per profile and bank, `months_with_delta` should be explained only by
     the expected deltas: SIB history duplicates that legacy double-counted now disappear, and
     Mashreq FX rows gain AED estimates. Anything else blocks the rest of the cutover.
9. **Switch the web app.** Promote the `apps/web` Vercel project to the production domain and
   remove the domain from the legacy project. Sign in as both members and check Overview,
   Activity and Cards & Statements against legacy numbers.
10. **Point the scraper at v2** (in `scraper/.env`):
    ```dotenv
    CCS_SCRAPER_TARGET_URL=https://nkmylznisjcnmqbxosey.supabase.co
    CCS_SCRAPER_UPLOAD_PATH=/functions/v1/statements-upload
    CCS_SCRAPER_SUPABASE_ANON_KEY=<anon key>
    HUSSAIN_CCS_SCRAPER_API_TOKEN=ccs_…    # new v2 tokens, scope statements:upload,
    TEJASVIE_CCS_SCRAPER_API_TOKEN=ccs_…   # one per profile
    ```
    - v2 tokens belong to one profile. Create one per profile in Settings → Sources → Tokens.
      `--profile <name>` picks `<NAME>_CCS_SCRAPER_API_TOKEN`, falling back to the global
      `CCS_SCRAPER_API_TOKEN` (remove the legacy global token so a missing profile token fails
      fast instead of uploading with the wrong one).
    - Run `ccs-scraper upload-pending --profile hussain` to confirm the upload path. Already
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
      and `email-ingest-microsoft.yml`, and the legacy CI jobs.
    - Delete `backend/`, `frontend/`, `deploy/Dockerfile.api`, `deploy/Dockerfile.frontend`,
      `deploy/Dockerfile.gmail-relay` and the legacy `docs/operations` and `docs/security`
      notes.
    - Optionally `select cron.unschedule('ledger-legacy-choices')` (in a migration).
    - Dropping the `legacy` schema is a separate, explicit decision. Take a final `pg_dump`
      first.

### Rollback

| Failure point | Rollback |
|---|---|
| Before step 4 | Resume Render, re-enable the MS workflow and the scheduler job. Nothing changed. |
| Steps 4–8 (v2 schema applied, parity not signed off) | Stop the v2 cron by deleting the Vault secret `edge_cron_secret`, which makes `invoke_edge` skip, or unschedule `ledger-worker-kick`. Move the legacy tables back: in one transaction, `alter table legacy.<t> set schema public` and `alter type legacy.<type> set schema public` for every table and enum listed in `20261008000000_quarantine_legacy.sql`. Rename or drop the clashing v2 tables first; `profiles`, `banks`, `categories`, `category_rules`, `statements`, `statement_lines`, `email_mailboxes` and `audit_events` share names. As a last resort, restore `legacy-<date>.dump` into a fresh project. Then resume Render and the legacy jobs and repoint nothing (no external endpoints were switched yet). |
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
- **Secret rotation:**
  - `CRON_SECRET`: update Vault `edge_cron_secret` and the function secret together.
  - `PARSER_SECRET`: see §3.
  - Service tokens: revoke and re-create in Settings.
  - OAuth clients: rotate in Google or Azure, then `supabase secrets set`.
  - Mailbox tokens: Set refresh token in Settings.
- **Backups:** the free tier has no downloadable automated backups. Take a monthly
  `supabase db dump --linked -f ledger-$(date +%F).sql` (schema) and `--data-only` (data). The
  PDFs are also on the laptop (`scraper/downloads`) and in email.
- **Pause protection:** if the project pauses, `ops-heartbeat` misses and alerts. Restore it
  from the dashboard.
