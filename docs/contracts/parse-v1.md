# Parser contract v1 (`services/parser` ⇄ `supabase/functions/worker`)

The parser is a stateless Cloud Run service. It never touches the database. The
`worker` Edge Function calls it and hands the JSON response verbatim to the SQL RPC
`public.ingest_parsed_document(p_doc_code text, p_payload jsonb)`.

## Request

`POST /parse`

Headers:
- `X-Parser-Secret: <shared secret>` (required; constant-time compared)
- `sentry-trace`, `baggage` (optional; continued as a Sentry trace)

Body (JSON):

```json
{
  "document_url": "https://<project>.supabase.co/storage/v1/object/sign/statements/...",
  "filename": "ADCB_20260801_statement.pdf",
  "bank_code_hint": "ADCB",
  "settings": {
    "FAB_PDF_PASSWORD": "…",
    "ADCB_PDF_PASSWORD": "…",
    "ADCB_CID": "…",
    "ENBD_PDF_PASSWORD": "…",
    "EIB_PDF_PASSWORD": "…",
    "SIB_PDF_PASSWORD": "…",
    "MASHREQ_PDF_PASSWORD": "…"
  }
}
```

- `bank_code_hint` may be null. The parser then detects the bank from the PDF text, trying each password.
- With a hint, the hinted parser runs first and the bank is also detected from the PDF. If the
  hinted parse fails with `UNSUPPORTED_LAYOUT`, `PDF_DECRYPT_FAILED` or `PARSE_OUTPUT_INVALID`, or
  finds no lines at all, and detection names a different bank, the parser retries **once** as the
  detected bank. The response then carries the detected `bank_code` (ingest updates the document's
  bank from it) and every statement starts with the warning `Bank hint <HINT> did not match this
  PDF; parsed as <BANK> (detected from the PDF)`. If the retry fails too, the hinted outcome is
  returned. A hinted parse that found lines is kept, with the warning `This PDF looks like <BANK>,
  not <HINT>; parsed as <HINT> because of the bank hint` when detection disagrees.
- `settings` holds the profile's PDF passwords: the keys `set_profile_secret` accepts
  (`<BANK>_PDF_PASSWORD` for FAB, ADCB, ENBD, EIB, SIB and MASHREQ, plus `ADCB_CID`). The worker
  sends every key the profile has stored (`worker_document_context`). Each bank parser uses its own
  key; detection, page counting and totals try all of them. Unknown keys are ignored.

## Response 200

All money values are **decimal strings, absolute (non-negative)**, except `totals.opening_balance` and `totals.closing_balance`, which are signed. Line sign is carried by `direction`. Dates are ISO `YYYY-MM-DD`.

```json
{
  "contract_version": 1,
  "parser_version": "2026.10.0",
  "bank_code": "ADCB",
  "document_kind": "statement_pdf",
  "statements": [
    {
      "kind": "statement",
      "bank_code": "ADCB",
      "statement_reference": "1234567890",
      "reference_source": "explicit",
      "statement_date": "2026-08-01",
      "period_start": "2026-07-02",
      "period_end": "2026-08-01",
      "due_date": "2026-08-26",
      "primary_card_last4": "3687",
      "card_holder": "HUSSAIN ABBASI",
      "card_type": "VISA PLATINUM",
      "totals": {
        "opening_balance": "1520.30",
        "closing_balance": "3410.00",
        "total_debits": "2500.00",
        "total_credits": "610.30",
        "min_due": "170.50",
        "credit_limit": "27000.00"
      },
      "warnings": [],
      "metadata": {},
      "lines": [
        {
          "line_no": 1,
          "txn_date": "2026-07-03",
          "txn_time": null,
          "posting_date": "2026-07-04",
          "description_raw": "CARREFOUR CITY CENTRE DUBAI AE",
          "merchant_normalized": "CARREFOUR CITY CENTRE DUBAI AE",
          "amount_original": "52.25",
          "currency_original": "AED",
          "amount_aed": "52.25",
          "fx_rate": null,
          "direction": "debit",
          "kind": "purchase",
          "country_code": "AE",
          "card_last4": "3687",
          "card_holder": null,
          "legacy_fingerprint": "9f86d0…"
        }
      ]
    }
  ]
}
```

Field rules:
- `document_kind` is `statement_pdf` or `history_pdf`. SIB "transaction history" exports are `history_pdf`.
- `statements[].kind` is `statement` or `history_extract`. A `history_pdf` produces only `history_extract` statements.
- `reference_source` is `explicit`, `fallback` or null.
- `totals` contains every key. A value is null when that parser doesn't extract it. FAB, ENBD/EIB and
  MASHREQ extract all six; ADCB only the two balances; SIB none. MASHREQ's summary block is used only
  when all of its lines are present and add up (otherwise the balances stay null and a warning says so).
  FAB's `total_credits` includes credits that the summary's Payments/Credits column leaves out
  (rewards redemptions, dispute credits): it is what the row's own Total Payment Due implies.
- `totals.opening_balance` and `totals.closing_balance` are **signed** decimal strings: positive = amount owed, negative = card in credit (e.g. `"-1579.06"`). All other totals (`total_debits`, `total_credits`, `min_due`, `credit_limit`) are absolute.
- `lines[].direction` is `debit` or `credit`. Sign normalisation happens in the parser; SIB history is inverted at source.
- `lines[].kind` is one of `purchase | refund | payment | fee | interest | cash_advance | adjustment`.
- `amount_aed` is null when the bank does not print the AED amount (e.g. SIB history foreign rows).
- MASHREQ foreign rows (`<merchant> <ref> MYR 500.00 @0.9400 470.00`) are split into
  `currency_original`, `amount_original` and `fx_rate` (the printed rate); `description_raw` is the
  merchant only. `legacy_fingerprint` is still computed from the unsplit text, as legacy did.
- `fx_rate` is AED per one unit of `currency_original`, as a decimal string, or null. An AED line is
  always `"1"`. A foreign line has the bank's printed rate (MASHREQ `@0.9400`, ADCB `[1 EUR=AED …]`)
  or the ratio of the two amounts; null when unknown or when it would round to zero at 8 places.
- `legacy_fingerprint` is `domain.parsing.utils.fingerprint_for(...)`, computed exactly as the legacy backend did. It is used to carry legacy category overrides across.
- `country_code` is an **ISO 3166-1 alpha-2** code or null. Statements print a trailing token in
  several forms; the parser maps ISO alpha-3 (`ARE` → `AE`, `IRL` → `IE`), `UAE` and the UAE emirate
  codes FAB prints for domestic merchants (`DXB`, `AUH`, `SHJ`, `AJM`, `FUJ`, `RAK`, `UAQ`, `AAN`)
  to alpha-2, and anything else to null: `YOU` ("THANK YOU"), `FEE`, `USD`, typos, and alpha-3
  codes that are also common words (`VAT`, `CAN`, `AND`, …). Best effort: the token is read from
  free text.
- A `history_extract` is a **window**, not a complete record of its cycle. Ingest unions the lines of every document of a statement by `(line_key, occurrence)`, so a later, shorter export never removes lines an earlier one contributed (ARCHITECTURE §4).

### Output validation

The parser validates every 200 response against `ccs_parser/contract.py` before returning it.
The rules mirror the database constraints, so a parser bug surfaces as a contract error with
field paths instead of a failed ingest:

| Field | Rule |
|---|---|
| every date | ISO `YYYY-MM-DD`, a real calendar date, year 2000–2100 |
| `period_start`, `period_end` | `period_start ≤ period_end`; for `kind = statement` the period is at most **100 days** |
| `due_date` (`kind = statement`) | on or after `statement_date`, at most **120 days** after it |
| `primary_card_last4`, `card_last4` | `^[0-9]{4}$` or null. The parser drops a malformed value to null rather than failing. |
| `txn_time` | `HH:MM[:SS[.ffffff]]`, a real time, or null |
| money | decimal strings within `numeric(14,2)` (≤ 12 integer digits); only `opening_balance` / `closing_balance` may be negative |
| `fx_rate` | within `numeric(18,8)` and **> 0**, or null |
| `currency_original` | `^[A-Z]{3}$` |
| `legacy_fingerprint` | 64 lowercase hex characters |
| `statements` | at least one; unknown keys are rejected everywhere |

A violation is the permanent 422 `PARSE_OUTPUT_INVALID`. Its message lists the failing field
paths only, never the values.

ENBD and EIB print the wrong year at the Dec/Jan boundary (`29-Dec-25 to 28-Jan-25`). The
parser re-derives the period years from the summary row's full Statement Date, else the newest
posting date (`domain/parsing/period_years.py`).

### Resource limits

Each parse runs in a short-lived child process (`ccs_parser/limits.py`). The size and page
checks run before any text extraction.

| Limit | Default | Env override | Breach |
|---|---|---|---|
| Downloaded file | 25 MB | `PARSER_MAX_DOWNLOAD_MB` | `DOWNLOAD_FAILED` (422) |
| PDF size | 15 MB | `PARSER_MAX_PDF_MB` | `PDF_TOO_LARGE` |
| Pages | 30 | `PARSER_MAX_PAGES` | `PDF_TOO_LARGE` |
| Inflated content streams, per parse | 32 MB | `PARSER_MAX_INFLATE_MB` | `PDF_TOO_LARGE` |
| Address space of the child (Linux) | 768 MB | `PARSER_MEMORY_LIMIT_MB` | `PDF_TOO_LARGE` |
| CPU time (`RLIMIT_CPU`) | 30 s | `PARSER_CPU_LIMIT_SECONDS` | `PARSE_TIMEOUT` |
| Wall clock (the child is killed) | 60 s | `PARSER_PARSE_TIMEOUT_SECONDS` | `PARSE_TIMEOUT` |

Real statements need about 1 s of CPU, at most 8 pages and under 2 MB inflated. The worker's
HTTP timeout (`PARSER_TIMEOUT_MS`, default 75 s) must stay above the parser's 60 s kill, and
Cloud Run's request timeout (120 s) above both. `PARSER_ISOLATION=inline` (tests and debugging
only) parses in-process: the size, page and inflate checks still apply, the CPU, wall-clock and
memory limits do not.

## Response 4xx/5xx

```json
{ "error": { "code": "PDF_DECRYPT_FAILED", "message": "…" } }
```

| Status | Codes | Meaning |
|---|---|---|
| 401 | `UNAUTHORIZED` | Missing or wrong `X-Parser-Secret` |
| 422 | `PDF_DECRYPT_FAILED`, `UNSUPPORTED_BANK`, `UNSUPPORTED_LAYOUT`, `BANK_UNDETECTED`, `DOWNLOAD_FAILED`, `INVALID_REQUEST`, `PARSE_TIMEOUT`, `PDF_TOO_LARGE`, `PARSE_OUTPUT_INVALID` | **Permanent.** The same PDF will always fail the same way. |
| 500 | `INTERNAL_ERROR` | Unexpected parser error |
| 502 | `DOWNLOAD_FAILED` | Transient Storage failure: timeout, network error, or a 429/5xx from Storage |

`DOWNLOAD_FAILED` is 422 when the URL itself is unusable (not https, host not allowed, a 4xx
from Storage other than 429, an empty or oversized file) and 502 when the download merely failed.
`INVALID_REQUEST` is a request body that doesn't match the schema.

### Worker classification

The worker (`supabase/functions/worker/parse_document.ts`, `classifyParserResponse`) decides by
**code**, not by status:

- **Permanent** only when the status is 422 **and** the body is a parse-v1 error envelope whose
  `code` is one of the nine 422 codes above. `fail_document(permanent)` marks the document
  `failed` with that code. No retry.
- **Transient** otherwise, including 401/403/404/405/400/413 (a wrong `PARSER_URL`, a Cloud Run
  IAM change, a proxy), a 422 without a known code, a 200 without a parse-v1 body, 5xx and
  timeouts. Non-load statuses are flagged as configuration problems in Sentry (fingerprinted per
  status). The message is re-sent with backoff (60 s, 5 min, 15 min, 30 min) and dead-lettered
  after 5 attempts (`MAX_ATTEMPTS`).
- After a 200, `ingest_parsed_document` errors are permanent for SQLSTATE class 22, `23502` and
  `23514` (the payload's content is rejected, `INGEST_<sqlstate>`) and transient otherwise (for
  example `23505`, `40P01`, `57014`).

A misconfiguration therefore never fails documents for good: fix it, and the retries or
`requeue_documents` pick them up.
