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
    "SIB_PDF_PASSWORD": "…"
  }
}
```

- `bank_code_hint` may be null. The parser then detects the bank from the PDF text, trying each password.
- `settings` uses the same keys as the legacy runtime settings consumed by `parsers/dispatcher.py`.

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
      "primary_card_last4": "9208",
      "card_holder": "ALICE SAMPLE",
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
          "card_last4": "9208",
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
- `totals` contains every key. A value is null when that parser doesn't extract it yet.
- `totals.opening_balance` and `totals.closing_balance` are **signed** decimal strings: positive = amount owed, negative = card in credit (e.g. `"-1579.06"`). All other totals (`total_debits`, `total_credits`, `min_due`, `credit_limit`) are absolute.
- `lines[].direction` is `debit` or `credit`. Sign normalisation happens in the parser; SIB history is inverted at source.
- `lines[].kind` is one of `purchase | refund | payment | fee | interest | cash_advance | adjustment`.
- `amount_aed` is null when the bank does not print the AED amount (e.g. Mashreq foreign rows).
- `fx_rate` is AED per one unit of `currency_original`, as a decimal string, or null.
- `legacy_fingerprint` is `domain.parsing.utils.fingerprint_for(...)`, computed exactly as the legacy backend did. It is used to carry legacy category overrides across.

## Response 4xx/5xx

```json
{ "error": { "code": "PDF_DECRYPT_FAILED", "message": "…" } }
```

| Status | Codes |
|---|---|
| 401 | `UNAUTHORIZED` |
| 422 | `PDF_DECRYPT_FAILED`, `UNSUPPORTED_BANK`, `UNSUPPORTED_LAYOUT`, `BANK_UNDETECTED`, `DOWNLOAD_FAILED`. These are permanent; the worker marks the document failed and does not retry. |
| 5xx | Transient. The worker retries through the pgmq visibility timeout, and moves the message to the DLQ after 5 reads. |
