# ccs-parser

Stateless PDF statement parser for the ledger-v2 architecture. Runs on Cloud Run,
never touches a database, and exposes one endpoint that implements
[`docs/contracts/parse-v1.md`](../../docs/contracts/parse-v1.md). The Supabase
`worker` Edge Function calls it and hands the JSON response to
`public.ingest_parsed_document`.

The bank parsers (FAB, ADCB, ENBD, EIB, SIB, Mashreq) are **copies** of the legacy
`backend/ccs_platform` parsers, kept behaviourally identical and verified with a
golden parity suite. The service adds: decimal-string money with `direction`,
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
├── scripts/
│   ├── build_golden.py     # builds golden fixtures by running the LEGACY parser
│   └── _legacy_runner.py   # executed with backend/.venv (imports ccs_platform)
├── tests/                  # unit tests, ported legacy tests, golden parity
├── Dockerfile
├── pyproject.toml
└── requirements.txt        # pinned, generated with `uv pip compile`
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

Regenerate pins after changing `pyproject.toml` dependencies:

```bash
uv pip compile pyproject.toml -o requirements.txt --python-version 3.12
```

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
| `POST` | `/parse` | `X-Parser-Secret` | Contract parse-v1. Downloads `document_url` (30 s timeout, 25 MB max), detects the bank when `bank_code_hint` is null, parses in a resource-limited child process (see `ccs_parser/limits.py`), validates the output against the DB constraints, returns statements. |
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
- `fx_rate` passes through the legacy `fx_rate_to_aed` (so AED lines report `"1"`).
- The legacy unknown-card sentinel `"0000"` is emitted as `null` in `card_last4` /
  `primary_card_last4` (the fingerprint still uses `"0000"`, as legacy did).
- `statement_date` never falls back to today: an undeterminable date is `UNSUPPORTED_LAYOUT`.
- `kind = interest` for debit fee/purchase lines mentioning `INTEREST`, `PROFIT CHARGE`,
  `FINANCE CHARGE` or `MURABAHA PROFIT` (VAT lines excluded). Other kinds are legacy.

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

### Golden parity

`tests/test_golden_parity.py` compares the new service with the legacy backend parser
on real statements. Golden files live in `tests/golden/` (gitignored — they contain
private statement data). Build them with the legacy backend's virtualenv present
(`backend/.venv`):

```bash
.venv/bin/python scripts/build_golden.py                      # default: ../../data/archive
.venv/bin/python scripts/build_golden.py --pdf-dir /path/to/pdfs
pytest -q tests/test_golden_parity.py
```

The builder de-duplicates PDFs by SHA-256 and records PDFs the legacy parser cannot
handle (e.g. still-encrypted copies); for those the test only asserts that the new
service fails with a classified 4xx error code. The parity test is skipped when the
golden directory is empty.

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

`--allow-unauthenticated` is required because the Supabase worker authenticates with
`X-Parser-Secret` rather than a Google identity token. Store the same secret value
in Supabase (Edge Function secret) for the worker. Rotate by adding a new secret
version, redeploying, then updating the worker.
