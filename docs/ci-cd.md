# CI/CD — Ledger v2

How code gets from a laptop to production, and what checks it on the way. The patterns come
from `mm-ecommerce` (path-filtered CI, a pre-push hook that mirrors CI, queued deploys behind
an environment, job summaries) and `another app` (iOS built and signed on the Mac, uploaded to
TestFlight by a Linux runner).

```
 commit ──► pre-commit      staged files only: secrets guard, append-only migrations,
                            eslint / deno lint / ruff / shellcheck / actionlint      (seconds)
 push ────► pre-push        CI mirror for the changed areas: lint, typecheck, test, build,
                            pgTAP (if the local stack runs), swift test             (≈1–2 min)
                            + main push that changes the iOS app: build, sign, stage the IPA
 GitHub ──► ci.yml          same checks, path-filtered, one required check: ci-ok
   main ──► deploy-supabase.yml   pgTAP → [production approval] → history check → db push → functions
        ──► deploy-parser.yml     ruff/pytest → [production approval] → image → no-traffic revision
                                  → /health smoke → 100% traffic
        ──► Vercel (Git integration) builds apps/web ──► web-smoke.yml probes production
        ──► ios-testflight.yml    staged IPA → App Store Connect → external testers
```

---

## 1. Workflows

| Workflow | Triggers | What it does |
|---|---|---|
| `ci.yml` | every PR, push to `main`, manual | Path-filtered jobs (below) + `ci-ok` aggregator. PRs cancel superseded runs; `main` runs always finish. |
| `deploy-supabase.yml` | push to `main` touching `supabase/migrations/**`, `supabase/functions/**` (not `_tests/`), `supabase/config.toml`; manual (type the project ref) | pgTAP + deno → `production` env → migration history check → dry run → destructive guard → `db push` → `functions deploy`. |
| `deploy-parser.yml` | push to `main` touching `services/parser/**` (not tests/docs); manual (type `deploy`) | ruff + pytest → `production` env → build/push image → deploy a **no-traffic tagged revision** → smoke `/health` on the tag URL → promote to 100%. |
| `web-smoke.yml` | push to `main` touching the web app (waits for that commit's Vercel Production deployment); daily 05:17 UTC; manual (any URL) | `scripts/ci/web-smoke.sh` against https://<web-host>. Does not deploy. |
| `ios-testflight.yml` | push to `main` touching `apps/ios/**` except `build-number.json` / `*.md`; manual | Linux only: verify the staged IPA matches this source → upload to App Store Connect → `testflight-distribute.mjs` to "Friends & Family". |
| `security.yml` | Mondays 03:00 UTC; manual | pip-audit + bandit on the parser. |

Deleted with the legacy code: `deploy-backend.yml`, `deploy-frontend.yml`,
`deploy-gmail-relay.yml`, `email-ingest-microsoft.yml`, and the legacy jobs in `ci.yml` and
`security.yml`. The repository variable `LEGACY_DEPLOYS_ENABLED` is no longer read by anything:
`gh variable delete LEGACY_DEPLOYS_ENABLED`.

### 1.1 CI jobs (`ci.yml`)

| Job | Runs when these change | Steps | Runner |
|---|---|---|---|
| `tooling` | `.github/workflows/**`, `scripts/hooks/**`, `scripts/ci/**`, `scripts/install-hooks.sh`, `scripts/cutover/*.sh`, `apps/ios/scripts/*.sh`, `.claude/hooks/**` | actionlint (incl. shellcheck of `run:` blocks), shellcheck (incl. `apps/ios/scripts/*.sh`), `sql_executed_text_test.py`, `.claude/hooks/guard_test.py`; pre-push also runs `apps/ios/scripts/release_checks_test.sh` on macOS | Linux |
| `supabase` | `supabase/migrations|tests/**`, `seed.sql`, `config.toml`, `packages/db-types/**`, `check-migrations.sh` | types normaliser tests → append-only check vs PR base / previous `main` (only if migrations changed) → `supabase start` → `db reset` → `test db` (pgTAP) → types drift vs `packages/db-types` (`gen-types.mjs --check`, normalised) | Linux |
| `edge` | `supabase/functions/**`, `config.toml` | `deno lint` → `deno fmt --check` → `deno check --frozen` → `deno test --frozen -A` (the frozen `deno.lock` must match the sources) | Linux |
| `parser` | `services/parser/**`, `docs/contracts/**` | uv venv → `ruff check` → `pytest` | Linux |
| `web` | `apps/web/**`, `packages/**`, root `package.json`, lockfile, workspace | tokens check → lint → typecheck → test → build | Linux |
| `scraper` | `scraper/**` | uv venv → `pytest` | Linux |
| `ci-ok` | always | fails if any job failed or was cancelled; skipped = passed; writes a results table to the job summary | Linux |

Editing `ci.yml` itself re-runs every job. A manual run runs every job.

**Caching:** pnpm store (`setup-node cache: pnpm`), uv (`setup-uv enable-cache`, keyed on the
requirements/pyproject), Deno (`setup-deno cache: true`, keyed on `deno.lock`), Docker layers
for the parser image (`type=gha`).

**Cost:** GitHub runs no macOS job at all (macOS minutes bill at 10x). Everything that needs a
Mac runs in the pre-push hook on your Mac and must pass before the push leaves it: LedgerKit
`swift test` (LedgerKit or tokens changed), the unsigned app + share extension compile (app code
changed, on any push except one to `main`), and on a push to `main` that changes the app, the
signed archive (§2.4). On a machine without Xcode these checks FAIL rather than skip, since no
CI job backs them up: push iOS changes from a Mac. The TestFlight upload runs on Linux.

---

## 2. Deploys and release flows

All production jobs use the **`production`** environment, never cancel midway
(`cancel-in-progress: false`, queued per workflow), refuse any ref but `main`, and write a
summary (what, which commit, how to roll back) to the run page.

`AUTO_DEPLOY` (repository variable): set it to `false` to turn push-triggered deploys of
Supabase into plan-only dry runs and to skip push-triggered parser deploys. Manual dispatch
still deploys.

### 2.1 Supabase (database + Edge Functions)

1. Merge/push to `main` with a change under `supabase/`.
2. `plan` decides: migrations changed → `db push`; function sources/config changed →
   `functions deploy`. (A change to only the workflow file plans a migrations dry run.)
3. `test`: fresh local stack, migrations from scratch, pgTAP; `deno lint` + `deno check --frozen` + `deno test --frozen` (a lock that no longer matches stops the deploy).
4. `deploy` waits for approval on `production`, then:
   - `supabase link`
   - **History check** (`scripts/ci/check-migrations.sh remote linked`): fails if a migration
     applied in production has no file in the repo, if a pending migration is older than the
     newest applied one, or if an applied migration's file **differs from the statements
     production recorded when it ran it** (`supabase migration fetch`, whitespace-insensitive).
     Migrations are append-only: fix forward with a new migration.
   - `supabase db push --dry-run` (pending list also in the job summary)
   - **Destructive guard**: `DROP TABLE|SCHEMA|COLUMN`, `TRUNCATE` or `DELETE FROM` that *runs* when a
     pending migration is applied stops a push-triggered run. Comments and the bodies of
     `create function|procedure` don't count (a redefined function deletes only when called);
     top-level statements, `DO` blocks and `cron.schedule($$…$$)` commands do
     (`scripts/ci/sql_executed_text.py`, tests `sql_executed_text_test.py`; check a file with
     `bash scripts/ci/check-migrations.sh destructive <file>`). Take a backup (Dashboard → Database →
     Backups, or `supabase db dump --linked`), then dispatch manually with `allow_destructive`.
   - `supabase db push`, then verify nothing is still pending
   - `SENTRY_RELEASE` secret + `supabase functions deploy --use-api` (all functions;
     `verify_jwt` from `config.toml`)
5. Function secrets and Vault entries are **not** managed here (PRODUCTION.md §2.4–2.5).

Manual: Actions → Deploy Supabase → Run workflow (from `main`) → type the project ref; tick
`dry_run` to only see what would run.

```bash
gh workflow run deploy-supabase.yml --ref main -f confirm_project_ref=<project-ref> -f dry_run=true
```

**Rollback:** migrations do not roll back. Write a new migration that undoes the change and
push it. For functions, revert the commit on `main` (the revert redeploys them); the workflow
only deploys `main`'s tip.

The same append-only rule is checked earlier: on every PR and push (`ci.yml` → `supabase`),
in pre-push (against `origin/main`) and in pre-commit (staged edits to files on `origin/main`).

### 2.2 Parser (Cloud Run)

1. Push to `main` with a change under `services/parser/` (or dispatch with `deploy`).
2. `test`: ruff + pytest.
3. `deploy` (approval on `production`): auth (Workload Identity Federation only), build + push
   `me-central1-docker.pkg.dev/<gcp-project>/ledger/ccs-parser:<sha7>`, then
   `gcloud run deploy --no-traffic --tag sha-<sha7>` with the same flags as PRODUCTION.md §3.
4. Smoke the **tag URL** `/health`: `status == ok` and `parser_version` equals
   `services/parser/pyproject.toml`'s version (retries for a cold start).
5. Only then `update-traffic --to-latest`, remove the tag, re-check the public `/health`.

A failed build or smoke test leaves production on the previous revision. **Rollback** after a
promotion (the summary prints the exact command):

```bash
gcloud run services update-traffic ccs-parser --project <gcp-project> \
  --region me-central1 --to-revisions <previous-revision>=100
```

### 2.3 Web (Vercel)

**Decision: keep Vercel's Git integration; add a post-deploy smoke test, not a CLI deploy.**

- Vercel already builds Production from every `main` push (project `cc-statement-scraper`,
  root `apps/web`). A CLI deploy workflow on top would double-deploy; replacing the
  integration would add a `VERCEL_TOKEN` with account-wide scope to GitHub and duplicate the
  build environment (`VITE_*`, `SENTRY_*`) that already lives in Vercel.
- **Preview deployments are off** (decision, audit X-32): a preview would run unreviewed
  branch code against the production Supabase project with the production CSP, and its auth
  redirects aren't allow-listed. Set in Vercel → Settings → Git → Ignored Build Step ("Only
  build production"); PRODUCTION.md §4 has the rationale. PRs are checked by `ci.yml` → `web`.
- What the integration lacks is a check that what it shipped works. Vercel reports each
  deployment back to GitHub as a Deployment; `web-smoke.yml` runs once per push to `main`
  that touches the web app, waits until production serves that commit or a newer one (each build stamps its commit in
  `<meta name="ledger-build">`; Vercel doesn't always report its deployments to GitHub), and checks
  the production URL (it no longer listens to `deployment_status`, which created a skipped run for
  every state of every deployment): `/` is 200 with `<title>Bank Ledger</title>`, the CSP
  is present and allows `https://<project-ref>.supabase.co` with
  `frame-ancestors 'none'`, `X-Frame-Options: DENY`, `nosniff`, HSTS, the SPA deep link
  `/activity` is 200 HTML, a hashed asset is 200 + `immutable`, a missing asset is 404.
- Web correctness before deploy is `ci.yml` → `web` (and branch protection on `ci-ok`).
  Vercel builds `main` regardless of CI, so a direct push with red CI still deploys: push
  through PRs, or let the pre-push hook stop it.

Flow: push to `main` → Vercel builds → Production deployment `success` → `web-smoke.yml`.
Run it by hand: `pnpm smoke:web` or `gh workflow run web-smoke.yml -f url=<url>`.

**Rollback:** Vercel → cc-statement-scraper → Deployments → last good Production deployment →
**Instant Rollback** (or `vercel rollback <deployment-url>`).

Vercel setting to confirm: Project → Settings → Git → GitHub deployment status reporting is on
(the default). Without it `web-smoke.yml` only runs daily and manually.

### 2.4 iOS (TestFlight)

Built and signed on the Mac (free), uploaded by a Linux runner (1x), as in another app:

1. Commit iOS changes, `git push` to `main`.
2. The **pre-push hook**, after every check passes, sees app code changed
   (`apps/ios/{Ledger,LedgerKit,ShareExtension,Ledger.xcodeproj,Config}/` or
   `apps/ios/project.yml`; never `build-number.json` alone) and `exec`s
   `apps/ios/scripts/publish-build.sh`, which bumps the build number, tests, archives, signs,
   checks the release config, sends dSYMs and the release to Sentry, stages `Ledger.ipa` +
   `build-meta.json` on the rolling prerelease **`ios-ledger-staged`**, and commits
   `apps/ios/build-number.json`. `SKIP_RELEASE=1 git push` skips the release (checks still run).

   Release config (BACKLOG IOS-21r). A Release build reads only the gitignored
   `apps/ios/Config/Secrets.Release.xcconfig`; the local `Secrets.xcconfig` is included from
   `Debug.xcconfig` only, so a key dropped from the release file is empty, never a local value.
   Three checks, all in `apps/ios/scripts/release-config-check.sh`, shape only, no value printed:
   - the **"Check release config"** Run Script phase (every target, `project.yml`) fails a
     Release build whose `LEDGER_*` settings are empty, local, not `production` or a placeholder;
   - `testflight.sh` runs it on the archive, and `publish-build.sh` on the IPA it stages:
     `plutil` reads the app's **and** every extension's Info.plist (share extension, widgets) (`LedgerSupabaseURL`
     https and not local/private, `LedgerEnvironment` = `production`,
     `LedgerSupabasePublishableKey` `sb_publishable_…`, `LedgerSentryDSN` non-empty).

   Sentry (`apps/ios/scripts/sentry-release.sh`, run by `testflight.sh` after the check):
   uploads dSYMs, then `sentry-cli releases new` / `set-commits --auto --ignore-missing` /
   `finalize` for `ledger-ios@<version>+<build>` (the name the app reports, LedgerKit
   `Telemetry.releaseName`). A Sentry failure, a missing token or a missing sentry-cli is a
   warning: Sentry never blocks a release. `SENTRY_AUTH_TOKEN` comes from the shell or the login
   keychain item `ledger-sentry-auth-token`
   (`security add-generic-password -U -s ledger-sentry-auth-token -a "$USER" -w`, which
   prompts), never an xcconfig, where it would be an Xcode build setting; `testflight.sh`
   refuses a `Secrets.Release.xcconfig` that still defines it. `SENTRY_ORG` / `SENTRY_PROJECT`
   (not secrets) come from the shell or `Secrets.Release.xcconfig`; the project defaults to the
   DSN's project id. `apps/ios/scripts/release_checks_test.sh` tests all of it against fixture
   plists and fake `sentry-cli` / `security` (pre-push `tooling`, macOS only).
3. The push triggers `ios-testflight.yml`:
   - `stage` (no secrets): downloads `build-meta.json`; ships only if its `commit` is this
     commit or differs from it **only** by `apps/ios/build-number.json`. Otherwise it says so in
     the summary and stops (not a failure).
   - `upload` (`testflight` env): re-checks the staged commit is the one `stage` approved,
     uploads with `apple-actions/upload-testflight-build@v5` (App Store Connect API key).
   - `distribute`: `node apps/ios/scripts/testflight-distribute.mjs --build <n> --timeout 35`
     waits for processing, attaches the build to "Friends & Family", submits for Beta App Review.
     Internal testers get it automatically.

Contract with `apps/ios/scripts/publish-build.sh` (owned by the iOS release): release tag
`ios-ledger-staged`; assets `Ledger.ipa` and `build-meta.json` with
`{"build": <int>, "commit": "<sha>", "apps": [{"scheme": "Ledger", "ipa": "Ledger.ipa", ...}]}`;
it commits `apps/ios/build-number.json` itself; `--keep-build` reuses the number.
`testflight-distribute.mjs` accepts `ASC_KEY_P8` as PEM or base64.

Without the hook (another machine, no Xcode): `git pull && apps/ios/scripts/publish-build.sh`,
push the counter commit (or re-run the workflow). To build and upload entirely from the Mac:
`apps/ios/scripts/testflight.sh && node apps/ios/scripts/testflight-distribute.mjs`.

---

## 3. Local hooks

```bash
bash scripts/install-hooks.sh        # or: pnpm hooks:install — once per clone
```

| Hook | What |
|---|---|
| `pre-commit` | Staged files only, seconds: refuses `.env*` (not `.env.example`), `*.p8`, `*.p12`, `*.mobileprovision`, `Secrets*.xcconfig` (not the example); refuses edits/deletes of migrations on `origin/main`; eslint on staged `apps/web` TS, `deno lint` on staged function TS, `ruff` on staged parser Python, `py_compile` on staged scraper Python, shellcheck/actionlint on staged scripts/workflows. |
| `pre-push` | CI mirror for the areas the push changes (vs the remote branch, or `origin/main` for a new branch), cheapest first, then a PASS/FAIL/WARN/SKIP summary with timings; plus the iOS checks CI no longer runs (`swift test`, the app compile). Then the iOS release step (§2.4). |
| `prepare-commit-msg`, `commit-msg` | Commit author must be `Hussain Abbasi <h_abbasi97@hotmail.com>`; no `Co-Authored-By`. |

Pre-push behaviour:

- **Fast path:** no CI-relevant files (docs only) → exits immediately.
- **Blocking:** anything CI would fail on. **Warn, not block:** missing toolchain/venv,
  and Supabase when Docker or the local stack isn't running or the local DB is
  behind the repo's migrations (CI runs pgTAP regardless). `PRE_PUSH_DB_RESET=1 git push`
  lets the hook `supabase db reset` first (wipes local data).
- `SKIP_PRE_PUSH=1 git push` skips everything; `SKIP_RELEASE=1` skips only the iOS release;
  `git push --no-verify` is git's bypass.
- By hand: `pnpm check` (changed vs upstream, incl. uncommitted), `pnpm check:all`,
  `pnpm check:plan` (dry run: prints what would run), `PRE_PUSH_AREAS=web,parser pnpm check`.

Area rules live in `area_of()` in `scripts/hooks/pre-push` and in the `changes` job of
`ci.yml`; change both together.

Other root scripts: `pnpm web:lint`, `web:typecheck`, `tokens:check`, `edge:lint`, `edge:test`,
`db:migrations:check`, `lint:workflows`, `smoke:web`.

---

## 4. Secrets and variables

Repository: `hussu97/cc-statement-scraper`. Names only; values never go in the repo.

| Name | Kind | Scope | Used by | Value / how to get it |
|---|---|---|---|---|
| `SUPABASE_ACCESS_TOKEN` | secret | env `production` | deploy-supabase | supabase.com → Account → Access Tokens |
| `SUPABASE_DB_PASSWORD` | secret | env `production` | deploy-supabase | project DB password |
| `SUPABASE_PROJECT_REF` | secret | env `production` | deploy-supabase, deploy-parser | `<project-ref>` |
| `GCP_WIF_PROVIDER` | variable | repo | deploy-parser | `projects/<number>/locations/global/workloadIdentityPools/github/providers/github-oidc` (§5) |
| `GCP_DEPLOY_SA` | variable | repo | deploy-parser | `github-deployer@<gcp-project>.iam.gserviceaccount.com` (§5) |
| `GCP_PROJECT_ID` | variable | repo | deploy-parser | optional; defaults to `<gcp-project>` |
| `ASC_KEY_ID` | secret | repo or env `testflight` | ios-testflight | App Store Connect → Users and Access → Integrations → key id (same key as another app) |
| `ASC_ISSUER_ID` | secret | repo or env `testflight` | ios-testflight | issuer id on the same page |
| `ASC_KEY_P8` | secret | repo or env `testflight` | ios-testflight | the `.p8` file (PEM or base64) |
| `AUTO_DEPLOY` | variable | repo | deploy-supabase, deploy-parser | optional; `false` = push runs plan-only / skipped |

```bash
R=hussu97/cc-statement-scraper

# Environments (production: approval + main only; testflight: tracking only)
ME=$(gh api user --jq .id)
gh api -X PUT repos/$R/environments/production --input - <<JSON
{"reviewers":[{"type":"User","id":$ME}],
 "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
gh api -X POST repos/$R/environments/production/deployment-branch-policies -f name=main -f type=branch
gh api -X PUT repos/$R/environments/testflight

# Supabase (prompted, so values stay out of shell history)
gh secret set SUPABASE_ACCESS_TOKEN -R $R --env production
gh secret set SUPABASE_DB_PASSWORD  -R $R --env production
gh secret set SUPABASE_PROJECT_REF  -R $R --env production --body <project-ref>

# GCP via WIF (after §5)
gh variable set GCP_WIF_PROVIDER -R $R --body "projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/github-oidc"
gh variable set GCP_DEPLOY_SA    -R $R --body "github-deployer@<gcp-project>.iam.gserviceaccount.com"

# App Store Connect (same key as another app)
gh secret set ASC_KEY_ID    -R $R --body '<key id>'
gh secret set ASC_ISSUER_ID -R $R --body '<issuer id>'
gh secret set ASC_KEY_P8    -R $R < ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8

# Cleanup from v1
gh variable delete LEGACY_DEPLOYS_ENABLED -R $R
gh secret list -R $R            # delete legacy ones (Render, legacy Vercel, Gmail relay, MS ingest, GCP_PROJECT_ID secret)
```

Required reviewers on an environment in a **private** repository need GitHub Pro/Team. On the
Free plan the `production` environment still scopes the secrets and records deployments, but
nobody is asked to approve: set `AUTO_DEPLOY=false` if every production change must be a
deliberate manual dispatch.

### 4.1 Status: configured on 2026-10-08

Names only. The repo is on the GitHub **Free** plan (private), so required reviewers and branch
protection are not available.

| Item | Where | State |
|---|---|---|
| `production` environment | repo | exists (merged with Vercel's `Production`; names are case-insensitive); branch policy **`main` only**; required reviewer **not set** (plan) |
| `testflight` environment | repo | exists, no rules |
| `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD` | env `production` | set |
| `SUPABASE_ACCESS_TOKEN` | env `production` | set 2026-10-08 (token `github-actions-<project>-prod`). `supabase link` needs read access to secret API keys and the Auth / PostgREST / network config as well as Edge Functions + secrets write; see PRODUCTION §10.1 |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | env `testflight` | set (same key as another app) |
| `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`, `GCP_PROJECT_ID`, `AUTO_DEPLOY` (`true`) | repo variables | set |
| `LEGACY_DEPLOYS_ENABLED` | repo variable | absent |
| Legacy repo secrets (`CCS_*`, `GCP_PROJECT_ID`, `RENDER_DEPLOY_HOOK`, `VERCEL_DEPLOY_HOOK`) | repo | still present; unused by v2. `GCP_SA_KEY` was **deleted** (2026-10-09): `deploy-parser` authenticates with WIF only |
| WIF pool `github`, provider `github-oidc` | GCP | created; condition: this repo and environment `production` or `Production` (the claim may carry the stored capitalisation) |
| `github-deployer@` SA, no keys | GCP | `run.admin` on service `ccs-parser`, `artifactregistry.writer` on repo `ledger`, `iam.serviceAccountUser` on `ccs-parser@`, `workloadIdentityUser` for the repo principalSet |
| Artifact Registry repo `ledger` (me-central1) | GCP | created |
| Branch protection on `main` (`ci-ok`) | repo | **not available** on Free (rulesets too) |

---

## 5. One-time GCP setup: Workload Identity Federation

Lets `deploy-parser` get short-lived GCP credentials from GitHub's OIDC token: no key in
GitHub. Only `production`-environment jobs of this repository can use it.

```bash
PROJECT=<gcp-project>
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
REPO=hussu97/cc-statement-scraper
SA=github-deployer@$PROJECT.iam.gserviceaccount.com

gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project $PROJECT

# Deployer service account: deploy Cloud Run, push images, act as the runtime SA.
gcloud iam service-accounts create github-deployer --project $PROJECT --display-name "GitHub Actions deployer"
gcloud projects add-iam-policy-binding $PROJECT --member "serviceAccount:$SA" --role roles/run.admin
gcloud projects add-iam-policy-binding $PROJECT --member "serviceAccount:$SA" --role roles/artifactregistry.writer
gcloud iam service-accounts add-iam-policy-binding ccs-parser@$PROJECT.iam.gserviceaccount.com \
  --project $PROJECT --member "serviceAccount:$SA" --role roles/iam.serviceAccountUser

# Pool + GitHub OIDC provider, restricted to this repo's production environment.
gcloud iam workload-identity-pools create github --project $PROJECT --location global \
  --display-name "GitHub Actions"
gcloud iam workload-identity-pools providers create-oidc github-oidc --project $PROJECT \
  --location global --workload-identity-pool github --display-name "GitHub OIDC" \
  --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment,attribute.ref=assertion.ref" \
  --attribute-condition "assertion.repository == '$REPO' && assertion.environment == 'production'"

# Allow that identity to impersonate the deployer SA.
gcloud iam service-accounts add-iam-policy-binding $SA --project $PROJECT \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/$REPO"

echo "GCP_WIF_PROVIDER=projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/github-oidc"
echo "GCP_DEPLOY_SA=$SA"
```

Then set the two variables (§4). There is no service-account key: `deploy-parser` is WIF-only and
the repo secret `GCP_SA_KEY` has been deleted (check `gcloud iam service-accounts keys list --iam-account $SA` shows only system-managed keys). The Artifact Registry repo `ledger` and the
runtime SA `ccs-parser@` come from PRODUCTION.md §3.

---

## 6. Branch protection

Require **`ci-ok`** only. It always reports (the CI workflow has no top-level path filter), so
a docs-only PR is never stuck waiting, and adding a job never means editing protection rules.

```bash
gh api -X PUT repos/hussu97/cc-statement-scraper/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["ci-ok"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

Recommendations: no force pushes or deletion of `main` (the TestFlight gate and the migration
history check rely on history); `enforce_admins: false` keeps direct pushes possible for the
single maintainer, so the pre-push hook is the gate on that path. Branch protection on private
repos also needs GitHub Pro; on Free, the hooks + `ci-ok` + the deploy workflows' own tests are
the gates.

---

## 7. Known gaps / follow-ups

- **History check against production: done 2026-10-08** (`supabase link --project-ref
  <project-ref> && bash scripts/ci/check-migrations.sh remote linked`): 25 applied,
  0 pending, every applied migration's statements identical to the repo file. Re-run it by
  hand before a deploy if in doubt; `deploy-supabase` runs it on every deploy anyway.
- The local dev DB may lag the repo's migrations; the pre-push hook then skips pgTAP with a
  warning until `supabase db reset`.
- `supabase/config.toml` changes (auth settings etc.) are not pushed by any workflow; apply
  them in the dashboard or with `supabase config push` deliberately.
- The scraper is not deployed (it runs on a laptop); CI only tests it.
- **Edge dependency lock.** `supabase/functions/deno.json` freezes `deno.lock`, and the edge runtime
  bundles with it. After changing an import in `_shared/deps.ts` (or a test import), refresh the lock
  in the same commit: `cd supabase/functions && deno check --frozen=false . && deno test --frozen=false -A .`.
  CI, pre-push and the deploy job fail on a stale lock. `supabase functions deploy` has no
  `--frozen` flag, so the deploy job's frozen `deno check` is the gate.
