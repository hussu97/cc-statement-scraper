# Audit 03: Server-side code (Edge Functions, parser, scraper upload, cutover script)

Branch `ledger-v2` @ `4ec697c`. Audited on 2026-10-08, before the production cutover.

**Scope:** `supabase/functions/**` (including `_shared`, `_tests` and the `[functions.*]` sections
of `config.toml`), `services/parser/**` (including the Dockerfile and requirements),
`git diff main..ledger-v2 -- scraper/`, `scripts/migrate_legacy.py` and
`docs/contracts/parse-v1.md`. SQL was read only where server code depends on it.

**Suites run:**

| Suite | Result |
|---|---|
| `deno test -A .` | 70 passed, 1 ignored (e2e needs `LEDGER_E2E=1`) |
| Parser `pytest` | 196 passed, 6 skipped. Golden parity ran locally against the private golden corpus. |
| Parser `ruff` | clean |
| Scraper `test_client`, `test_cli_upload`, `test_config` | 67 passed |

Experiments live in the session scratchpad under `audit-server/`: `mkbomb.py`, `runbomb.py`,
`b64cost.ts`, `classify.ts` and `form21.ts`.

**Severity:**
- **P0:** must fix before cutover (security or data loss).
- **P1:** fix before cutover if possible.
- **P2:** fix soon after cutover.
- **P3:** nice to have.

"Unverified" marks a claim I reasoned from code or docs but did not reproduce.

## Findings

| ID | Sev | Category | Location | Summary |
|---|---|---|---|---|
| SRV-01 | P1 | security / reliability | `services/parser/ccs_parser/app.py:190-219`, `service.py:178-237`, `detection.py:12-32`, `totals.py:230-246` | No CPU, time, page or decompression limit on parsing. A 65 KB crafted PDF burned 202 s of CPU. |
| SRV-02 | P1 | bug | `scraper/scraper/client.py:80-131`, `scraper/scraper/cli.py:260-276`; `statements-upload/form.ts:9,35` | The scraper never splits uploads. More than 20 PDFs per bank gets a 413 with no retry, so a `--months` backfill can never upload. |
| SRV-03 | P1 | bug | `supabase/functions/worker/parse_document.ts:27-28` | Any non-contract 4xx from the parser URL (404/403/400/413 from Cloud Run, the GFE or a wrong `PARSER_URL`) permanently fails the document. |
| SRV-04 | P2 | reliability | `worker/index.ts:58-77`, `parse_document.ts:132`, `_shared/cron.ts:14-19` | Worker budget (50 s) + parser timeout (100 s) + ingest (≤120 s) exceed the Edge wall clock (150 s free). Isolates are killed mid-round. |
| SRV-05 | P2 | reliability / data loss | `gmail-push/index.ts:46-114` | No time budget and no incremental cursor in gmail-push. A large backlog never finishes, and a 404 reset silently skips mail with no alert. |
| SRV-06 | P2 | reliability / security | `statements-upload/index.ts:22-34,55-64` | Upload buffers up to about 501 MB in memory (20 × 25 MB). There is no cap at all when `content-length` is absent. |
| SRV-07 | P2 | perf | `_shared/gmail.ts:131-135`, `outlook-poll/graph.ts:86-94` | Base64 decode through `Uint8Array.from(callback)` takes ~1 s of CPU per 20 MB, against a 2 s Edge CPU limit. |
| SRV-08 | P2 | bug | `services/parser/ccs_parser/detection.py:35-82` | Substring bank detection is order-dependent. A merchant or transfer text naming another bank wins. |
| SRV-09 | P2 | bug | `scripts/migrate_legacy.py:171-231` | Legacy PDFs are imported without a bank hint (they rely on SRV-08 detection). A conflict leaves orphan Storage objects, and a missing profile crashes the script. |
| SRV-10 | P2 | reliability | `ops-monitor/health.ts`, `ops_health()` | Nothing alerts on stale mailboxes, expired Gmail watches, mailbox `last_error` or parse-queue age. |
| SRV-11 | P2 | test-gap | `supabase/functions/_tests/*` | No tests for the worker state machine, gmail cursor handling, outlook resume, `ingestAttachment`/`storeDocument` races, token rotation or viewer uploads. |
| SRV-12 | P3 | perf | `PRODUCTION.md:194-195`, `worker/index.ts` | 1 vCPU with concurrency 4 and GIL-bound parses, plus overlapping worker runs during the bulk legacy import, risks timeouts (unverified). |
| SRV-13 | P3 | security (supply chain) | `supabase/functions/deno.json:3`, `services/parser/requirements.txt`, `Dockerfile:2` | `lock: false`, no pip hashes, base image not digest-pinned. |
| SRV-14 | P3 | reliability | `_shared/oauth.ts:79-81`, `gmail-push/index.ts:130-136` | Rotated refresh-token save errors are ignored, and gmail-push never records `last_error`. |
| SRV-15 | P3 | bug | `_shared/email_ingest.ts:39-52` | `saveSyncState` writes back a whole stale JSON snapshot (last writer wins), so the cursor can regress. |
| SRV-16 | P3 | bug | `scraper/scraper/upload_state.py:47-58` | `uploaded.json` is written non-atomically. A corrupt file is silently treated as empty, then overwritten. |
| SRV-17 | P3 | bug | `services/parser/ccs_parser/service.py:195-199` | A bank hint skips detection entirely, so a wrong hint is a permanent failure with no fallback. |
| SRV-18 | P3 | security | `_shared/sentry.ts:40-46`, `_shared/http.ts:49-56` | Free-text scrubber doesn't strip emails, though the docs say it does. Raw PG messages (constraint names) reach clients. |
| SRV-19 | P3 | reliability | `gmail-push/index.ts:116-139` | Permanent errors (400 envelope, `invalid_grant`) make Pub/Sub redeliver for up to 7 days. No dead-letter topic. |
| SRV-20 | P3 | bug | `_shared/documents.ts:80-81`, `worker/parse_document.ts:80-81` | Re-uploading a failed PDF says `duplicate` and never re-parses. A duplicate queue message flips a parsed document back to `parsing`/`failed`. |
| SRV-21 | P3 | readability (contract) | `docs/contracts/parse-v1.md:111-115`, `contract.py:52-68` | Contract drift: `INVALID_REQUEST` 422 is undocumented, the worker keys on status rather than code, and `card_last4`/`txn_time` are unvalidated. |
| SRV-22 | P3 | reliability (noise) | `ops-monitor/health.ts:38-55` | DLQ and `documents_stuck` alerts fire every 15 min until a manual SQL purge, including during the bulk import. |
| SRV-23 | P3 | readability | several | Duplicated helpers, double `validatePdf`, `ProviderHttpError` living in `gmail.ts`, long `processParseMessage`. |
| SRV-24 | P3 | test-gap | `services/parser/tests/test_golden_parity.py:25` | Golden parity is skipped in CI because the corpus is private and gitignored. |

**Counts:** P0 0 · P1 3 · P2 8 · P3 13 (24 total).

Auth itself held up:
- `verify_jwt=false` functions all authenticate in code.
- The cron secret check fails closed and is constant-time.
- Service tokens decide the profile, and `X-Profile-Key` and `profile_code` mismatches are rejected.
- A JWT uploader must be an owner (RLS read of `profile_members`). `ingest_sms` asserts owner.
- Gmail OIDC checks signature (RS256), issuer, audience, `exp`, `email` and `email_verified`.
- The parser compares its secret with `hmac.compare_digest` and fails closed. It never follows redirects, and `PARSER_ALLOWED_HOSTS` is set in production (non-empty; value not printed).
- Python Sentry runs with `include_local_variables=False` and `max_request_body_size="never"`.

No P0 found.

---

## Details

### SRV-01 (P1, security/reliability): parser has no resource limits; a tiny PDF ties up a parser instance

**Location:** `services/parser/ccs_parser/app.py:190-219` (sync handler in the threadpool),
`service.py:178-237`, `detection.py:12-32`, `totals.py:230-246`. Deploy settings are in
`PRODUCTION.md:195` (`--cpu 1 --concurrency 4 --timeout 120`).

**Problem:** `/parse` runs pdfplumber/pdfminer with no limits on:
- wall-clock or CPU time
- page count
- decompressed stream size

The same document is opened several times:
- detection, with each password candidate
- `pdf_open_state`
- the bank parser
- `read_text_lines` over **all** pages

Threads can't be cancelled. When the worker gives up at 100 s, or Cloud Run at 120 s, the thread
keeps burning the instance's only vCPU.

**Experiment:** `mkbomb.py 64` builds a 65,717-byte valid PDF whose one page holds a Flate
stream that inflates to 64 MB of `q Q` operators. Running `parse_document()` on it took
**202 s wall time and 184 MB peak RSS**, then raised `BANK_UNDETECTED`.

**Failure scenario:**
1. Anyone who can get a PDF into a routed mailbox sends this file. An empty `sender_allowlist`
   allows every sender, and owners and scraper tokens can upload directly too.
2. The worker times out at 100 s and records a transient `PARSER_TIMEOUT`.
3. The message is retried up to 5 times. Each retry starts another uncancellable thread.
4. Parse throughput stalls for every profile, and real statements time out and dead-letter too.

The upload limit is 25 MB, so a crafted file can be far worse than this one.

**Fix:**
- Run each parse in a child process with `RLIMIT_CPU`/`RLIMIT_AS` and a hard wall timeout below
  the worker's timeout, and kill it on expiry. For example, use `multiprocessing` with a
  per-request process, or `concurrent.futures.ProcessPoolExecutor` with `max_tasks_per_child=1`.
- Reject PDFs over N pages (for example 100) before extraction.
- Bound the total inflated stream size.
- Cap `read_text_lines` to the summary pages.
- In the worker, make `PARSER_TIMEOUT` permanent after 2 reads instead of 5.

### SRV-02 (P1, bug): scraper doesn't split uploads to the server's 20-file limit

**Location:** `scraper/scraper/client.py:80-131`, `scraper/scraper/cli.py:260-276`. The server
side is `supabase/functions/statements-upload/form.ts:9` (`MAX_FILES = 20`) and `:35`.

**Problem:** `_upload_groups` sends one request per bank with every PDF in that group. v2
rejects more than 20 files with `413 TOO_MANY_FILES`. The client treats every 4xx as
non-retryable. The legacy backend had no per-request file cap, so this is a regression.

**Experiment:** `form21.ts` with 21 files returns `413 TOO_MANY_FILES`. `ScraperClient` against a
mock 413 raised after **1 attempt**.

**Failure scenario:**
1. `ccs-scraper scrape --months 2025-01:2026-09` produces more than 20 statements for one bank.
2. That bank's upload fails.
3. `upload-pending` rebuilds the same oversized group, so it fails every time until someone
   uploads by hand.

**Fix:**
- In `upload_pdfs` or `_upload_groups`, split groups into ≤20 files, and also by total bytes,
  for example ≤50 MB per request.
- Record each successful chunk as it completes.
- Add a test with 21+ files.

### SRV-03 (P1, bug): worker treats any 4xx from the parser URL as a permanent document failure

**Location:** `supabase/functions/worker/parse_document.ts:27-28` (`classifyParserResponse`).

**Problem:** The contract defines a fixed set of permanent codes (`PDF_DECRYPT_FAILED`,
`UNSUPPORTED_*`, `BANK_UNDETECTED`, `DOWNLOAD_FAILED`, `INVALID_REQUEST`). The worker decides
by **status** instead, so every 4xx is permanent. 4xx responses that come from infrastructure
rather than the parser also mark documents `failed`:
- a wrong `PARSER_URL` path → 404
- a Cloud Run IAM change dropping `--allow-unauthenticated` → 403
- a GFE 400 or 413

**Experiment:** `classify.ts` shows 404, 403, 400 and 413 with no body all return
`{"action":"permanent","code":"HTTP_4xx"}`.

**Failure scenario:**
1. During the cutover, `migrate_legacy.py --step pdfs --apply` enqueues every legacy PDF.
2. A typo in `PARSER_URL` (or a missing `allow-unauthenticated`) permanently fails all of them.
3. Recovery needs `requeue_documents` per profile, and Sentry fills with
   `parse_permanent HTTP_404`.

**Fix:**
- Treat a 4xx as permanent only when the body is a parse-v1 error envelope whose `code` is in
  the permanent set.
- Treat everything else as transient, flagged as config (with a distinct Sentry fingerprint).
- Add tests for 404 and 403 with an HTML body.

### SRV-04 (P2, reliability): worker time budgets exceed the Edge Function wall clock

**Location:** `worker/index.ts:58-77` (`WORKER_BUDGET_MS=50000` is checked only before a round
starts), `parse_document.ts:132` (`PARSER_TIMEOUT_MS=100000`), and `ingest_parsed_document`
(120 s statement timeout). The work runs in `EdgeRuntime.waitUntil` (`_shared/cron.ts:16-17`).

**Problem:**
- A round that starts at t = 49 s can last 100 s (parser) plus ingest, which is past the 150 s
  wall clock on the free plan. The free plan is the documented hosting.
- The isolate is killed with three messages in flight. They become visible again only after the
  300 s visibility timeout, `read_ct` is burned, and the documents stay `parsing`.
- pg_cron starts a new worker every minute while older ones still run. This is safe for message
  exclusivity but multiplies parser load (see SRV-12).

**Fix:**
- Don't start a parse round unless `deadline - now ≥ PARSER_TIMEOUT + ingest margin`.
- Pick `WORKER_BUDGET_MS + PARSER_TIMEOUT_MS + margin < wall clock`, for example 20 s + 90 s.
- Lower `PARSER_TIMEOUT_MS` to match SRV-01's in-parser limit.
- Document these limits next to the visibility timeout.

### SRV-05 (P2, reliability/data loss): gmail-push can't make progress on a large backlog; 404 reset is silent

**Location:** `gmail-push/index.ts:46-114`, especially `:64-105` and `:69-73`.

**Problem:**
- Every history page and message is processed in one request, and the cursor is saved only at
  the end. `history.list` has no `labelId` filter, so every added message is fetched with
  `format=full`.
- With the Pub/Sub ack deadline at 120 s (`PRODUCTION.md:280`) and a 150 s wall clock, a
  backlog of a few hundred messages never completes. Pub/Sub keeps redelivering, and each
  attempt starts again from the same cursor.
- Once the cursor is older than Gmail's ~7-day history, the 404 branch resets it to the pushed
  id. Every unprocessed message in between is skipped for good, with no Sentry event.

Legacy did the same, and the cursor key carries over (`gmail_history_id`), so a short cutover is
fine. The risk is a multi-day outage.

**Fix:**
- Add a deadline, as `outlook-poll` has. Save the cursor after each fully processed page:
  carry `pageToken` in `sync_state`, or advance to the page's last processed history id.
- Pass `labelId` (the watch labels) to `history.list`.
- Emit `captureMessage("gmail cursor reset", level error)` on a 404 reset.
- Optionally run a time-bounded `messages.list q=has:attachment after:<last_synced_at>` backfill.

### SRV-06 (P2, reliability/security): statements-upload buffers huge bodies in memory

**Location:** `statements-upload/index.ts:22-23` (cap = 20 × 25 MB + 1 MB ≈ 501 MB, applied only
when `content-length` is present), `:30` (`req.formData()` buffers everything), and `:55-64`
(`arrayBuffer()` copies each file again).

**Problem:** Edge isolates have far less memory than 501 MB (256 MB on hosted plans,
unverified). A chunked request has no limit at all. The limit only applies after
authentication, but one bad client or a scraper bug can crash the isolate (546), and the
response then tells nobody which files were stored.

**Fix:**
- Require `content-length` and cap it at about 50-60 MB per request.
- Lower `MAX_FILES`, or cap total bytes.
- Pair this with SRV-02 so the scraper chunks to the same limit.

### SRV-07 (P2, perf): attachment base64 decoding is CPU-heavy against the 2 s Edge CPU limit

**Location:** `_shared/gmail.ts:131-135` (`Uint8Array.from(bin, c => c.charCodeAt(0))`) and
`outlook-poll/graph.ts:86-94` (same pattern).

**Experiment:** `b64cost.ts` decoded 20 MB in **~992 ms** on an M-series laptop. sha256 took 20 ms.

**Failure scenario:** One push carries two or three large statements. The CPU limit kills the
isolate, the cursor isn't saved (SRV-05), and the next delivery fails the same way.

**Fix:**
- Use `Uint8Array.fromBase64(s, {alphabet: "base64url"})` where the runtime supports it, or
  `jsr:@std/encoding` `decodeBase64Url`.
- Skip attachments whose `body.size` (Gmail) or `size` (Graph) exceeds 25 MB before downloading.

### SRV-08 (P2, bug): bank detection misfires on cross-bank text

**Location:** `services/parser/ccs_parser/detection.py:35-82`. The code is copied verbatim from
legacy.

**Experiment:** I fed `_infer_bank_code_from_text` synthetic first-page text for each case:

| Statement | Text that wins | Detected as |
|---|---|---|
| FAB | `TRANSFER EMIRATES NBD` | ENBD |
| ADCB | `EMIRATES ISLAMIC TAKAFUL` | EIB |
| Mashreq | `EMIRATES NBD ATM` | ENBD |
| SIB | `IPP TRANSFER MASHREQ BANK` | MASHREQ |

The EIB, ENBD and Mashreq checks run before the explicit "FIRST ABU DHABI BANK" and "SHARJAH
ISLAMIC BANK" markers. Golden parity passes on the real corpus, so the practical hit rate is
low.

**Failure scenario:** A hint-less web or iOS upload, or a legacy import (SRV-09), of a statement
with such a line is parsed by the wrong parser. The result is `UNSUPPORTED_LAYOUT` (permanent)
or, worse, a wrong parse.

**Fix:**
- Score all banks, preferring full legal names and header-only regions, and take the best match.
- Or test the explicit full-name markers for every bank first, then the heuristics.
- Add these negative cases as tests.

### SRV-09 (P2, bug): migrate_legacy imports PDFs without the known bank, and its error handling is thin

**Location:** `scripts/migrate_legacy.py:171-231`.

**Problems:**
1. `documents.bank_code` is left NULL even though `legacy.statements.bank_code` is known for every
   parsed legacy PDF. Parsing therefore depends on SRV-08 detection, while legacy scraper
   uploads were parsed with a hint. This is a parity risk.
2. The object is uploaded first, then `insert … on conflict do nothing`. On a conflict (two
   concurrent runs) the uploaded object becomes an orphan.
3. `cur.fetchone()[0]` raises `TypeError` when the metadata step hasn't created the profile.
4. Dry-run downloads every PDF from GCS. It's read-only, but slow.
5. In `step_secrets`, OAuth app credentials from several profiles silently overwrite each other
   (dict order).

Dry-run is otherwise truly read-only: every write is in a rolled-back transaction, Vault
included. Idempotency is by sha256.

**Fix:**
- Select `max(s.bank_code)` per file and insert it as `bank_code`.
- Insert the row before uploading, or delete the object when the insert affects 0 rows.
- Check that the profile exists with a clear message.
- Warn when app credentials differ between profiles.

### SRV-10 (P2, reliability): ops-monitor is blind to mailbox ingestion health

**Location:** `ops-monitor/health.ts:26-89` and `public.ops_health()`
(`supabase/migrations/20261008000900_queues_secrets_cron.sql`).

**Problem:** None of these alert:
- an expired Gmail watch (`watch_expires_at < now()`)
- a stale `last_synced_at`
- outlook `sync_state.last_error`
- a growing `parse_document` oldest-message age while documents are freshly updated
- a revoked refresh token (`invalid_grant`): Sentry captures it only as a generic exception, per push

**Failure scenario:** A Pub/Sub permission change or a lapsed watch stops all Gmail statements,
and nothing pages until the user notices.

**Fix:** Add `mailboxes_stale` (no sync in more than 2 days), `gmail_watch_expiring` (less than
24 h left) and `mailbox_errors` to `ops_health()` and `evaluateHealth`.

### SRV-11 (P2, test-gap): risky Edge paths have no tests

**Problem:** `_tests` only cover pure helpers. Nothing exercises:
- `processParseMessage`: status transitions, DLQ at `read_ct`, a failed `queueDelete` after a
  successful ingest, a missing object, `P0002`
- gmail-push `processMailbox`: cursor init, 404 reset, partial failure keeps the cursor, the
  `no_routes` advance
- `pollMailbox`: resume from `nextLink`, 410 restart, deadline
- `ingestAttachment` and `storeDocument`: the race (23505 → duplicate), object removal on insert
  failure
- `mailboxAccessToken` rotation persistence
- `runWorker` budget handling

The e2e test also never checks that a **viewer** JWT gets 403 on upload or SMS ingest.

**Fix:** Inject a fake `Db` (the functions already take `svc`) and a fake `fetch`. Add table-driven
tests for each path above, plus an e2e viewer case.

### SRV-12 (P3, perf, unverified): parser capacity during the bulk legacy import

**Problem:** Cloud Run runs `--cpu 1 --concurrency 4`, but pdfplumber is CPU-bound under the GIL,
so four concurrent parses each run about 4× slower. Overlapping worker runs (one per minute, 3
messages each) can hold about 12 in flight across 3 instances. Large statements may cross the
100 s timeout only during the import and dead-letter (`read_ct` 5).

**Fix:**
- Set `--concurrency 1` or 2 (more instances instead).
- Or cap in-flight parses in the worker with a `pg_try_advisory_lock`-style semaphore.
- Watch the canary step's timings.

### SRV-13 (P3, supply chain)

**Location:** `supabase/functions/deno.json:3` (`"lock": false`; transitive npm dependencies of
supabase-js, Sentry and the Anthropic SDK float), `services/parser/requirements.txt` (exact pins,
no `--generate-hashes`), and `Dockerfile:2` (`python:3.12-slim` by tag).
`uvicorn[standard]` also pulls in watchfiles and websockets, which the service doesn't need.

**Fix:**
- Commit `deno.lock` and deploy with `--frozen`.
- Run `uv pip compile --generate-hashes` and install with `pip install --require-hashes`.
- Pin the base image by digest.
- Use plain `uvicorn` plus `httptools`/`uvloop` if wanted.

### SRV-14 (P3, reliability): OAuth rotation and error bookkeeping

**Location:** `_shared/oauth.ts:79-81` ignores the `set_mailbox_secret` result.

**Problems:**
- If the save fails, the newest Microsoft refresh token is lost. Older ones usually stay valid,
  so the risk is low.
- gmail-push (`:130-136`) never writes `sync_state.last_error`, unlike outlook-poll, so the UI
  can't show "reconnect Gmail".

**Fix:** Check the RPC error and capture it as a warning. Record `last_error` in gmail-push and
gmail-watch-renew.

### SRV-15 (P3, bug): `saveSyncState` is a whole-document read-modify-write

**Location:** `_shared/email_ingest.ts:39-52`.

**Problem:** The function spreads the mailbox snapshot read at the start of the request. When
writers run concurrently (overlapping Pub/Sub deliveries, a push during watch-renew), an older
cursor or stale keys overwrite newer ones. Only reprocessing results, because ingestion is
idempotent, but it can multiply SRV-05's backlog.

**Fix:** Use a jsonb merge in SQL (`sync_state = sync_state || $patch`). For the cursor, keep the
maximum (`greatest` on a bigint cast) in an RPC.

### SRV-16 (P3, bug): `uploaded.json` corruption silently resets state

**Location:** `scraper/scraper/upload_state.py:47-58`.

**Problem:** `write_text` isn't atomic. If the process is interrupted mid-write, `_load`
swallows the JSON error and returns `{}`, and the next `record_many` overwrites the history. The
only effect is re-uploads (the server dedupes), but the swallowed error hides real problems.

**Fix:** Write to a temp file, then `os.replace`. On parse failure, log a warning and keep a
`.corrupt` copy.

Related: `_record_uploaded` (`cli.py:235-258`) matches the server's sanitised filename against
`pdf.name`. Names over 200 characters or with surrounding whitespace never get recorded.

### SRV-17 (P3, bug): a bank hint disables detection with no fallback

**Location:** `services/parser/ccs_parser/service.py:195-199`.

**Problem:** A wrong hint permanently fails the document (`UNSUPPORTED_LAYOUT` or decrypt
errors). A wrong hint can come from a user upload with the wrong bank picked, or a mis-scoped
email route.

**Fix:** When the hinted parser raises `UNSUPPORTED_LAYOUT`, run detection. If it returns a
different bank, retry once with that bank and add a warning.

### SRV-18 (P3, security/privacy hygiene)

**Location:** `_shared/sentry.ts:40-46` and `_shared/http.ts:49-56`.

**Problems:**
- `scrubString` strips bearer tokens, `ccs_` tokens, JWTs and URL queries, but not email
  addresses. ARCHITECTURE §10 says emails are scrubbed. Today emails only reach Sentry through
  keyed fields (filtered), so this is a latent gap.
- `pgErrorToHttp` returns the raw PG message for mapped 4xx codes, for example
  `duplicate key value violates unique constraint "…"`. This leaks schema names to clients.
- Unverified: whether the Deno SDK isolates `withScope` across concurrent requests in one
  isolate. If it doesn't, the `function`/`doc_code` tags could bleed between requests.

**Fix:**
- Add an email regex to `scrubString` (and the Python `_scrub_string`).
- Return a fixed message for 23505 and 23503.
- Add a concurrency test that interleaves two `withSentry` handlers.

### SRV-19 (P3, reliability): gmail-push nacks permanent errors forever

**Location:** `gmail-push/index.ts:116-139`.

**Problem:** These all return non-2xx, so Pub/Sub retries for up to the 7-day retention:
- a malformed envelope (400)
- a revoked token (502 → 500)
- a missing config (500)

That produces Sentry noise and wasted invocations.

**Fix:**
- ack (200) for permanently invalid envelopes.
- Set `last_error` and ack for `invalid_grant` (see SRV-14).
- Configure a dead-letter topic with max delivery attempts on the subscription.

### SRV-20 (P3, bug): duplicate and failed document semantics

**Location:** `_shared/documents.ts:80-81` and `worker/parse_document.ts:80-81`.

**Problems:**
- Re-uploading a PDF whose parse failed (for example, before the PDF password was set) returns
  `duplicate` and doesn't requeue. Users must find "requeue".
- A duplicate queue message for an already `parsed` document (a requeue while in flight, or a
  redelivery after the delete failed) sets `parse_status='parsing'`. A later permanent parser
  error then marks a document `failed` even though its statements are ingested.

**Fix:**
- Return `parse_status` with `duplicate`, and requeue automatically when the existing document
  is `failed`.
- In the worker, skip messages whose document is already `parsed` unless they were explicitly
  requeued (`requeue_documents` sets `queued`).

### SRV-21 (P3, contract drift)

**Location:** `docs/contracts/parse-v1.md:111-115` vs `services/parser/ccs_parser/app.py:31-40`
and `contract.py:52-68`.

**Problems:**
- `INVALID_REQUEST` is a permanent 422 but isn't listed in the 422 row.
- 502 `DOWNLOAD_FAILED` (transient) isn't mentioned.
- The doc implies classification by code, but the worker uses status (SRV-03).
- `card_last4`, `primary_card_last4` and `txn_time` aren't validated (`^\d{4}$`, `HH:MM[:SS]`),
  so a parser bug surfaces as a DB 22023 instead of a contract error.

**Fix:** Update the table and tighten the Pydantic types.

### SRV-22 (P3, alert noise)

**Location:** `ops-monitor/health.ts:38-55`.

**Problem:** A single DLQ message produces an `error` event every 15 minutes until someone
purges it with SQL (`PRODUCTION.md:550-555`). The alert rule is "any frequency", so that is a
page every 15 minutes. During the bulk import, `documents_stuck` (queued for over 1 h) can fire
on a legitimately draining backlog.

**Fix:**
- Alert on depth *increase* (store the last depth), or lower repeats to `warning`.
- Add a `drain_dlq`/`requeue_dlq` service RPC.
- Base `documents_stuck` on `parsing` older than 1 h, or on queue age over N h.

### SRV-23 (P3, readability)

**Problems:**
- Base64 decoding is duplicated (`gmail.ts:131`, `graph.ts:92`).
- `validatePdf` runs twice per file (in `statements-upload/index.ts:62` and inside
  `storeDocument`, and in `email_ingest.ts:88` plus `storeDocument`).
- `ProviderHttpError` lives in `gmail.ts` but is imported by Outlook.
- `processParseMessage` is about 120 lines mixing transport, classification and status writes.
- `failDocument` ignores its RPC error (`parse_document.ts:42-49`).
- The `documents` status update result is unchecked (`:80-81`).

**Fix:**
- Move the shared helpers to `_shared/provider.ts`.
- Have `storeDocument` own validation.
- Split `processParseMessage` into fetch, classify and apply steps.

### SRV-24 (P3, test-gap): golden parity never runs in CI

**Location:** `services/parser/tests/test_golden_parity.py:25`. The corpus is gitignored in
`services/parser/.gitignore:1`.

**Problem:** CI runs 0 parity cases. Parity is the main safety net for pdfplumber pins and parser
edits, and it currently passes only on the author's machine.

**Fix:** Commit a small redacted or synthetic golden set (one PDF per bank layout), or run the
private suite in a protected CI job with the corpus in encrypted storage.

---

## Fix status

Fixed on `ledger-v2` (uncommitted, 2026-10-08). Suites: `deno test -A .` 91 passed, 1 ignored; parser
`ruff check .` clean, `pytest` 272 passed, 6 skipped (golden parity ran on the private corpus: 92 cases);
scraper `pytest` 135 passed; `scripts/tests` 12 passed (run with `backend/.venv`).

| ID | Status | What changed / why |
|---|---|---|
| Sentry local-off | fixed | `_shared/sentry.ts` (`sentryActive`) and `ccs_parser/sentry.py` (`sentry_active`) never initialise when `SENTRY_ENVIRONMENT` is unset, `local`, `development` or `test`, even with a DSN. Unset defaults to `local`. Tests: `_tests/sentry_local_test.ts`, `test_sentry_scrubber.py`. The runtime test now uses `ci`. |
| SRV-01 | fixed | New `ccs_parser/limits.py`. Every `/parse` runs in a forkserver child process with `RLIMIT_CPU` 30 s, a 60 s wall clock (the child is killed), `RLIMIT_AS` 768 MB (Linux) and a bounded zlib for pdfminer (32 MB inflated per parse). Files over 15 MB or 30 pages are rejected before extraction, and `read_text_lines` is capped too. New permanent 422 codes: `PARSE_TIMEOUT` and `PDF_TOO_LARGE`. Audit experiment re-run (`audit-server/runbomb_limited.py`): `bomb64.pdf` and a 512 MB bomb give `PDF_TOO_LARGE` in 0.2 s (was 202 s). A 24 MB operator flood under the inflate budget gives `PARSE_TIMEOUT` at the CPU limit (31 s). Also verified through uvicorn on a spare port. Real statements need ≤1 s CPU, ≤8 pages and ≤1.5 MB inflated. |
| SRV-02 | fixed | The scraper client splits uploads into ≤20 files and ≤32 MB per request (`UPLOAD_MAX_FILES_PER_REQUEST`, `UPLOAD_MAX_BYTES_PER_REQUEST`; env `CCS_SCRAPER_UPLOAD_MAX_FILES` / `_MAX_MB`, clamped to the server limits). A 413 halves the batch recursively. A partial failure raises `UploadBatchError`, and `_upload_groups` records the batches that succeeded so `upload-pending` retries only the rest. |
| SRV-03 | fixed | `classifyParserResponse`: only a 422 whose body carries a code in `PERMANENT_PARSER_CODES` is permanent. Everything else is transient: 401/403/404/405/400/413, a 422 without a known code, a 200 without parse-v1, 5xx and timeouts. Transient failures retry with backoff (re-sent with `attempt` and a 60 s / 5 min / 15 min / 30 min delay, falling back to the VT) and dead-letter after 5 attempts. Config-type responses raise an error-level Sentry event with `http_status`, fingerprinted per status. |
| X-06 | fixed | `contract.py` now mirrors the DB: real calendar dates (years 2000–2100), `period_start ≤ period_end`, statement period ≤100 days, due date within 0–120 days after the statement date, last-4 `^[0-9]{4}$`, `txn_time`, amounts within numeric(14,2) and `fx_rate > 0`. A violation raises the permanent 422 `PARSE_OUTPUT_INVALID`, with field paths only and no values. Malformed last-4 values are dropped (null) rather than failing. The ENBD/EIB year is re-derived from the summary row's full-year Statement Date, else the newest posting date (`domain/parsing/period_years.py`). |
| X-06 Sentry detail | fixed | The ingest rejection event carries the SQLSTATE, the PG message with literal values filtered (object/constraint names kept, never `Failing row` details) and the constraint in the fingerprint. Transient events carry `error_message`, `http_status` or `sqlstate`. All class-22 errors, 23502 and 23514 (including `INGEST_22023` for card-less multi-account statements) are permanent. Ingest `warnings` are logged. |
| sms_fallback DLQ | fixed | Root cause in the local DLQ: the e2e probe SMS is not a transaction, but the schema forced an amount, so validation failed (`LLM_BAD_OUTPUT`). The schema now allows `msg_kind=other` with a null amount (`LlmNotApplicable`), which is skipped and deleted without a DLQ entry or alert. Deterministic failures go to the DLQ once with a sanitised `reason` (`dlqOnce`), and the reason is also in the DLQ record. `PROPOSE_*` now reports its SQLSTATE. An empty bank list gives `NO_BANKS` without an LLM call. SDK retries are off (the queue retries). |
| SRV-04 | fixed | `worker/budget.ts`: a round starts only if `wall clock (150 s, EDGE_WALL_CLOCK_MS) - 5 s - now ≥ need`. A parse round needs `PARSER_TIMEOUT_MS + 20 s`; an LLM round needs 65 s. The clock is measured from request start, and `WORKER_BUDGET_MS` still applies. `PARSER_TIMEOUT_MS` defaults to 75 s (above the parser's 60 s kill). |
| SRV-06 | fixed | `readBodyCapped`: 40 MB per request (`MAX_REQUEST_BYTES`), enforced on `content-length` and while streaming chunked bodies, before `FormData` parsing. |
| SRV-08 | fixed | `_infer_bank_code_from_text` scores every bank. Name markers are matched only outside date-led transaction rows (legal name 3, brand 2). Layout labels add up to 3. Ties go to the stronger name, then layout, then legacy order. If nothing scores, the legacy rules run. The four cross-bank cases (plus ENBD with an "EMIRATES ISLAMIC" merchant) are tests, and golden detection is unchanged. |
| SRV-09 | fixed (4 deferred) | The legacy bank is passed as `documents.bank_code` when all of a PDF's legacy statements agree on a supported bank. On an insert conflict or error the uploaded object is deleted. The upload still happens first because the INSERT trigger enqueues the parse. A missing profile exits with "run --step metadata". Differing OAuth app credentials across profiles print a warning (no values). Deferred: dry-run still downloads every PDF to compute sha256, which is slow but read-only. |
| DP-03 / DP-04 | fixed | See X-06. The three real ENBD PDFs now give Jan-2025 (29-Dec-24..28-Jan-25, 30 lines), Jan-2026 (29-Dec-25..28-Jan-26, 8 lines) and Dec-2025 (29-Nov-25..28-Dec-25, statement date 2025-12-28, due 2026-01-22). That recovers 38 lines. Golden parity allows this as an explicit delta (3 PDFs): day and month unchanged, the year re-derived, and the fallback reference re-dated. |
| DP-07 | fixed | The actual cause was the original-currency amount format, not a second section. FAB prints `EUR 108,99` (decimal comma) and `KWD 18.750` (3 dp), and `_parse_txn_row` dropped those rows. Both formats are now accepted for the original amount only; the AED column stays dot-decimal. Both affected statements now reconcile (488.40 + 488.55 AED). Golden parity allows the extra lines only if every legacy line is still present in order and the statement's debits now equal its own total (3 PDFs, 6 lines). |
| DP-13 | fixed | `--target local\|prod` is required. Local requires `LEDGER_DB_URL` and `SUPABASE_URL` on 127.0.0.1/localhost. Prod requires both to name `nkmylznisjcnmqbxosey` (pooler user or `db.<ref>` host). `--apply` against prod also needs `--yes-i-mean-prod <ref>` or the ref typed at a TTY prompt. Dry-run remains the default. `finalize` prints the new `legacy_lines_missing` / `legacy_aed_missing` columns. |
| SRV-05, 07, 10 | deferred | Contained in `gmail-push` / `outlook-poll` / `ops-monitor`, but each needs its own design and tests (cursor paging, base64 decoder swap, new `ops_health` checks in SQL, which is not owned here). Backlog. |
| SRV-11 | partly | New `_tests/worker_test.ts` covers the parse state machine (404/403/422/23514/22023/57014, DLQ at max attempts, send-before-delete), budget, backoff, SMS `NO_BANKS`, and the body cap. Gmail/Outlook/storeDocument paths are still untested. |
| SRV-12 … SRV-24 | deferred | P3. SRV-21 is partly done: `card_last4` and `txn_time` are now validated, and the worker keys on code. |

**Follow-ups for files outside this change set:**
- `docs/contracts/parse-v1.md`: add `PARSE_TIMEOUT`, `PDF_TOO_LARGE`, `PARSE_OUTPUT_INVALID` (422) and the new validation rules.
- `PRODUCTION.md` §10 step 7: add `--target prod --yes-i-mean-prod nkmylznisjcnmqbxosey` to every `migrate_legacy.py` line.
- `PRODUCTION.md` / Cloud Run: keep `--timeout 120`. The parser kills parses at 60 s.
- Root `README.md`: change `PARSER_TIMEOUT_MS` to `75000`, add `EDGE_WALL_CLOCK_MS` and `CCS_SCRAPER_UPLOAD_MAX_FILES/_MB`, and note that Sentry is off for local/development/test.
- `CHANGELOG.md` entry.
- Already-ingested ENBD rows: requeue the three affected documents. One is stored as 2026-12-28 and must be superseded, and its 8 `period_overlap` reviews dismissed.
- Already-ingested FAB rows: requeue the two FAB documents so the six recovered lines are ingested.

**Docs follow-ups done (2026-10-08, docs pass):** parse-v1 documents the new codes, limits,
output validation and code-based worker classification (completes SRV-21); PRODUCTION §10 step 7
uses `--target prod` with `--yes-i-mean-prod nkmylznisjcnmqbxosey`, §3 keeps `--timeout 120`
and documents the limits, step 8 has the ENBD/FAB post-import checks; README has
`PARSER_TIMEOUT_MS` 75000, `EDGE_WALL_CLOCK_MS`, the scraper batching variables and the Sentry
local behaviour; CHANGELOG has an "Audit fixes (pre-cutover)" section. Open items:
[BACKLOG.md](BACKLOG.md).

**SQL side for the Edge pass (2026-10-09, `20261009000400_db_ops_and_worker_rpcs.sql`):** SRV-10
(`ops_health` `mailboxes_stale`, `gmail_watch_expiring`, `mailbox_errors`), SRV-15
(`save_mailbox_sync_state`), SRV-20 (`begin_document_parse`, `resubmit_document`, `fail_document`
never un-parses) and SRV-22 (`drain_dlq`, `requeue_dlq`, `documents_stuck` = `parsing` > 1 h,
queue `newest_age_s` for alert-on-increase). The Edge Functions still have to call them.
