# ccs-parser

Stateless PDF statement parser for the ledger-v2 architecture. Runs on Cloud Run,
never touches a database, and exposes one endpoint that implements
[`docs/contracts/parse-v1.md`](../../docs/contracts/parse-v1.md). The Supabase
`worker` Edge Function calls it and hands the JSON response to
`public.ingest_parsed_document`.

The bank parsers (FAB, ADCB, ENBD, EIB, SIB, Mashreq) are **copies** of the legacy v1
backend parsers (removed from the repo after the cutover; see git history), kept
behaviourally identical and verified with a golden parity suite. The service adds: decimal-string money with `direction`,
contract kinds (`interest`), `fx_rate`, `legacy_fingerprint`, document/statement
kinds, statement identity, and best-effort `totals`.

## Layout

```
services/parser/
├── ccs_parser/
│   ├── app.py              # FastAPI: POST /parse, GET /health, /debug-sentry (non-prod)
│   ├── service.py          # parse_document(): PDF -> contract dict (no HTTP)
│   ├── contract.py         # pydantic models of parse-v1; mirrors the DB constraints (X-06)
│   ├── limits.py           # per-parse child process: CPU/wall/memory/pages/size/inflate limits
│   ├── detection.py        # bank detection: scored markers, line items ignored (legacy rules as fallback)
│   ├── totals.py           # best-effort statement totals extraction (never raises)
│   ├── kinds.py            # legacy kind -> contract kind mapping
│   ├── sentry.py           # Sentry init + before_send scrubber
│   ├── parser_adapter.py   # legacy parser_adapter (no date.today() fallback)
│   ├── banks/              # legacy bank parsers + dispatcher (copied)
│   └── domain/             # legacy parsing/statement models, utils, identity (copied)
├── tests/                  # unit tests, ported legacy tests, golden parity
├── Dockerfile
├── pyproject.toml
└── requirements.txt        # pinned with hashes, generated with `uv pip compile --generate-hashes`
```

## Setup

Requires Python 3.12+ and [uv](https://docs.astral.sh/uv/).

```bash
cd services/parser
uv venv --python 3.12 .venv
uv pip sync --python .venv/bin/python requirements.txt
uv pip install --python .venv/bin/python --no-deps -e .
uv pip install --python .venv/bin/python pytest ruff
source .venv/bin/activate
```

Regenerate pins (with hashes) after changing `pyproject.toml` dependencies:

```bash
uv pip compile pyproject.toml -o requirements.txt --python-version 3.12 --generate-hashes
```

The image installs them with `pip install --require-hashes --only-binary=:all:`, from a base image
pinned by digest (`Dockerfile`), and copies `ccs_parser/` without pip-installing it (no unpinned
build backend). Plain `uvicorn`, without the `[standard]` extras (SRV-13).

`pdfplumber` and `pdfminer.six` are pinned exactly: their text output drives every
parser regex. Re-run the golden parity suite before changing them.

## Run locally

```bash
cp .env.example .env   # set PARSER_SECRET
set -a && source .env && set +a
uvicorn ccs_parser.app:app --host 127.0.0.1 --port 8080
curl -s http://127.0.0.1:8080/health
curl -s -X POST http://127.0.0.1:8080/parse \
  -H "X-Parser-Secret: $PARSER_SECRET" -H "content-type: application/json" \
  -d '{"document_url": "https://<project>.supabase.co/storage/v1/object/sign/statements/x.pdf?token=…", "bank_code_hint": null, "settings": {}}'
```

Set `PARSER_ALLOW_HTTP=true` to fetch from a plain-http local file server while developing.

## API

| Method | Path | Auth | Notes |
|---|---|---|---|
| `POST` | `/parse` | `X-Parser-Secret` | Contract parse-v1. Downloads `document_url` (30 s timeout, 25 MB max), detects the bank when `bank_code_hint` is null, parses in a resource-limited child process (see `ccs_parser/limits.py`), validates the output against the DB constraints, returns statements. A wrong hint is retried once as the detected bank, with a warning (SRV-17). |
| `GET` | `/health` | none | `{"status": "ok", "parser_version", "contract_version"}` |
| `GET` | `/debug-sentry` | `X-Parser-Secret` | Raises an error to test Sentry. Not registered when `SENTRY_ENVIRONMENT=production`. |

Errors use `{"error": {"code", "message"}}`:

| Status | Code | Meaning |
|---|---|---|
| 401 | `UNAUTHORIZED` | Missing/invalid secret, or `PARSER_SECRET` unset (fails closed). |
| 422 | `PDF_DECRYPT_FAILED`, `UNSUPPORTED_BANK`, `UNSUPPORTED_LAYOUT`, `BANK_UNDETECTED` | Permanent parse failures. |
| 422 | `DOWNLOAD_FAILED` | Permanent download failure: storage 4xx, oversize, empty body, non-https or disallowed host. |
| 422 | `INVALID_REQUEST` | Request body failed validation. |
| 422 | `PARSE_TIMEOUT` | The parse exceeded its CPU (`PARSER_CPU_LIMIT_SECONDS`) or wall-clock (`PARSER_PARSE_TIMEOUT_SECONDS`) limit and was killed. |
| 422 | `PDF_TOO_LARGE` | Over `PARSER_MAX_PDF_MB` or `PARSER_MAX_PAGES`, inflated streams over `PARSER_MAX_INFLATE_MB`, or out of memory. |
| 422 | `PARSE_OUTPUT_INVALID` | The parser's own output broke the contract / DB constraints (e.g. `period_start > period_end`, bad last-4). Deterministic, so permanent. |
| 502 | `DOWNLOAD_FAILED` | Transient download failure: timeout, connection error, storage 429/5xx. |
| 500 | `INTERNAL_ERROR` | Unexpected error (retried by the worker). |

Implementation notes beyond the contract:

- Money is formatted from the legacy 2-dp values as absolute strings, except
  `totals.opening_balance` / `totals.closing_balance`, which are signed
  (negative = card in credit), per the contract.
- Fee classification uses whole words (`FEE(S)`, `CHARGE(S)`): unlike legacy,
  "COFFEE" or "RECHARGE" lines are no longer `fee`. Fingerprints and amounts are unaffected.
- `fx_rate` passes through the legacy `fx_rate_to_aed`, except that AED lines always report `"1"`
  and a rate that rounds to zero at 8 places is null (X-33).
- `country_code` is ISO 3166-1 alpha-2 or null (`countries.py`, X-25r): alpha-3, `UAE` and FAB's
  emirate codes (`DXB`, `AUH`, `SHJ`, …) map to alpha-2; words such as `YOU`, `FEE` or `VAT` are null.
- The legacy unknown-card sentinel `"0000"` is emitted as `null` in `card_last4` /
  `primary_card_last4` (the fingerprint still uses `"0000"`, as legacy did).
- `statement_date` never falls back to today: an undeterminable date is `UNSUPPORTED_LAYOUT`.
- `kind = interest` for debit fee/purchase lines mentioning `INTEREST`, `PROFIT CHARGE`,
  `FINANCE CHARGE` or `MURABAHA PROFIT` (VAT lines excluded). Other kinds are legacy.
- Mashreq foreign rows are split into currency, original amount and the printed rate (DP-11);
  legacy kept them as AED with that text in the description. The kind and `legacy_fingerprint`
  are still computed from the legacy description.
- Totals (`totals.py`): FAB, ENBD/EIB and Mashreq give all six values, ADCB the two balances, SIB
  none. FAB's `total_credits` adds the credits its Payments/Credits column omits (DP-10); Mashreq's
  summary is used only when complete and consistent (DP-12).
- Every PDF password in `settings` is tried for detection, page counting and totals; each bank
  parser uses its own key, including `EIB_PDF_PASSWORD` and `MASHREQ_PDF_PASSWORD` (X-17).

## Environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `PARSER_SECRET` | yes | — | Shared secret expected in `X-Parser-Secret`. |
| `PORT` | no | `8080` | Listen port (Cloud Run sets it). |
| `PARSER_ALLOWED_HOSTS` | no | any | Comma-separated allow-list of `document_url` hosts, e.g. `<project>.supabase.co`. |
| `PARSER_MAX_DOWNLOAD_MB` | no | `25` | Max PDF size. |
| `PARSER_ALLOW_HTTP` | no | `false` | Allow `http://` URLs (local dev only). |
| `PARSER_MAX_PDF_MB` | no | `15` | Larger PDFs fail with `PDF_TOO_LARGE` before any extraction. |
| `PARSER_MAX_PAGES` | no | `30` | More pages fail with `PDF_TOO_LARGE` (real statements have at most 8). |
| `PARSER_CPU_LIMIT_SECONDS` | no | `30` | `RLIMIT_CPU` of the per-parse child process (real parses take about 1 s). |
| `PARSER_PARSE_TIMEOUT_SECONDS` | no | `60` | Wall clock after which the parse child is killed. Keep below the worker's `PARSER_TIMEOUT_MS` (75 s). |
| `PARSER_MEMORY_LIMIT_MB` | no | `768` | `RLIMIT_AS` of the parse child (Linux only). |
| `PARSER_MAX_INFLATE_MB` | no | `32` | Total decompressed PDF stream bytes per parse (decompression-bomb guard; real statements use under 2 MB). |
| `PARSER_ISOLATION` | no | `process` | `inline` runs parses in the server process without CPU/wall/memory limits (tests and debugging only). |
| `SENTRY_DSN` | no | — | Enables Sentry when set (and the environment isn't local). |
| `SENTRY_ENVIRONMENT` | no | `local` | Sentry environment. `local`, `development`, `test` or unset never send events, even with a DSN. `production` also disables `/debug-sentry` and OpenAPI docs. |
| `SENTRY_RELEASE` | no | — | Sentry release (e.g. the git SHA). |
| `SENTRY_TRACES_SAMPLE_RATE` | no | `0.2` | Performance sampling rate. |
| `LOG_LEVEL` | no | `INFO` | Python log level. |

Sentry runs with `send_default_pii=False`, no request bodies, no local variables, and a
`before_send` scrubber (`ccs_parser.sentry.scrub_event`) that drops request bodies
(PDF passwords in `settings`), the `X-Parser-Secret`/`Authorization` headers, any
password/secret/token-like keys, and query strings of every URL (signed URL tokens).
Events are tagged with `bank_code` and `parser_version`. Incoming `sentry-trace` /
`baggage` headers continue the worker's trace.

## Tests

```bash
cd services/parser && source .venv/bin/activate
ruff check .
pytest -q
```

`tests/test_parsers.py` (ported) needs sample PDFs in `~/Downloads` and
`ADCB_SAMPLE_PASSWORD`; it is skipped otherwise.

### Synthetic golden set (runs in CI)

`tests/test_synthetic_golden.py` parses eight fictional statements (`tests/synthetic/cases.py`:
FAB, ENBD with the Dec/Jan year fix, EIB and Mashreq encrypted, ADCB, SIB history, a wrong bank
hint). Each is written as a PDF at test time by `tests/synthetic_pdf.py` (plain text placed like the
bank's layout; no real data) and compared with `tests/synthetic/expected/<case>.json`.

When parser output changes on purpose:

```bash
# 1. bump PARSER_VERSION in ccs_parser/__init__.py and version in pyproject.toml (they must match)
# 2. regenerate the snapshots and review the JSON diff
PARSER_ISOLATION=inline .venv/bin/python -m tests.synthetic.update
```

`tests/synthetic/versions.json` records the snapshot digest of every `PARSER_VERSION`. Changed
output under a version that is already recorded fails `test_snapshot_digest_matches_parser_version`,
and `update` refuses to record it, so `documents.parser_version` always tells old output from new
(NEW-2). New layouts get a case here.

### Golden parity

`tests/test_golden_parity.py` compares the service with the **legacy v1 parser's output**
on real statements. The golden files in `tests/golden/` (gitignored: they contain private
statement data and point at the local source PDFs under `data/archive/`) were built by
running the legacy parser before it was removed. They are **frozen**: the legacy code is
gone, so they can no longer be rebuilt or extended from this tree, and nothing regenerates them from the
current parser (that would turn the parity check into a self-comparison).

```bash
pytest -q tests/test_golden_parity.py
```

- PDFs the legacy parser could not handle (e.g. still-encrypted copies) only assert that
  the service fails with a classified 4xx error code.
- The only allowed differences from legacy are listed in the test and reported in the
  terminal summary: ENBD/EIB years corrected at the Dec/Jan boundary (DP-03/04), FAB
  `EUR 108,99` / `KWD 18.750` rows legacy skipped (DP-07), and `fee` → `purchase` from the
  whole-word fee classifier.
- A case whose source PDF has moved is skipped; the suite is skipped when `tests/golden/`
  is empty (fresh clones, CI).
- New layouts and banks are covered by the synthetic set and unit tests (`test_*.py`) rather
  than new golden files. The real corpus does not compare totals, `country_code` or `fx_rate`.
  To rebuild the fixtures from scratch, use a checkout of a commit that still has
  `backend/` and `scripts/build_golden.py` (e.g. `cdd77b1`, or the parent of
  `git log --diff-filter=D -1 -- services/parser/scripts/build_golden.py`).

## Deploy to Cloud Run

```bash
PROJECT=<gcp-project>
REGION=me-central1          # or your region
SERVICE=ccs-parser

# One-time: secrets
printf '%s' "$(openssl rand -hex 32)" | gcloud secrets create parser-secret --data-file=- --project "$PROJECT"
printf '%s' "<sentry-dsn>"            | gcloud secrets create parser-sentry-dsn --data-file=- --project "$PROJECT"

# Service account with secret access only
gcloud iam service-accounts create ccs-parser --project "$PROJECT"
for s in parser-secret parser-sentry-dsn; do
  gcloud secrets add-iam-policy-binding "$s" --project "$PROJECT" \
    --member "serviceAccount:ccs-parser@$PROJECT.iam.gserviceaccount.com" \
    --role roles/secretmanager.secretAccessor
done

# Build + deploy (from services/parser)
gcloud run deploy "$SERVICE" --source . --project "$PROJECT" --region "$REGION" \
  --service-account "ccs-parser@$PROJECT.iam.gserviceaccount.com" \
  --allow-unauthenticated \
  --cpu 1 --memory 1Gi --concurrency 4 --timeout 120 --max-instances 3 \
  --set-secrets PARSER_SECRET=parser-secret:latest,SENTRY_DSN=parser-sentry-dsn:latest \
  --set-env-vars SENTRY_ENVIRONMENT=production,SENTRY_RELEASE=$(git rev-parse --short HEAD),PARSER_ALLOWED_HOSTS=<project>.supabase.co
```

Capacity (SRV-12, measured 2026-10-08): a parse takes 0.9 s CPU (p95 1.1 s) and peaks at
150-180 MB RSS in its child process (95 local statements). In the image (1 vCPU, 1 GiB, amd64
under emulation), four concurrent parses of the largest statements peaked at 444 MiB and finished
in 14 s; eight would take 52 s, close to the 60 s kill. `--concurrency 4` is kept: Cloud Run never
sends an instance more than four, and each worker run sends at most three.

`--allow-unauthenticated` is required because the Supabase worker authenticates with
`X-Parser-Secret` rather than a Google identity token. Store the same secret value
in Supabase (Edge Function secret) for the worker. Rotate by adding a new secret
version, redeploying, then updating the worker.
