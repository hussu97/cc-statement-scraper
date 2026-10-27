# termsheet-v1: a structured note's terms

The shape `termsheet-extract` returns and `create_structured_note` takes. The model's answer
(`TERMSHEET_SCHEMA` in `supabase/functions/termsheet-extract/termsheet.ts`) is normalised into
it; the user reviews and corrects it in the app, adds what was bought, and the app sends it to
the RPC. Change this file, `termsheet.ts` and `create_structured_note`
(`supabase/migrations/20261027124257_structured_notes.sql`) together.

All numbers are decimal strings, all dates `YYYY-MM-DD`. Percentages are percent numbers
(`"98"` is 98%). A **level** is a percent of the underlying's initial level; an **amount** is a
percent of the nominal (denomination).

## Request: `POST /functions/v1/termsheet-extract`

User JWT; `multipart/form-data` with `profile_code` (owned by the caller) and `file` (one PDF,
at most 25 MB). The PDF is stored at `term-sheets/<profile_code>/<sha256>.pdf`.

## Response 200

```json
{
  "draft": {
    "name": "Example Bank B Athena AMZN/META/MSFT 2031",
    "terms": {
      "product_name": "5Y Athena Worst-of on Amazon.com Inc, Meta Platforms Inc and MICROSOFT CORP in USD",
      "isin": "XS0000000603",
      "issuer": "Example Bank B Issuance B.V.",
      "guarantor": "Example Bank B",
      "currency": "USD",
      "denomination": "1",
      "issue_price_pct": "54",
      "strike_date": "2026-08-27",
      "issue_date": "2026-09-11",
      "final_valuation_date": "2031-08-27",
      "maturity_date": "2031-09-04",
      "underlyings": [
        { "name": "Amazon.com Inc", "symbol": "AMZN", "bloomberg_code": "AMZN UW", "isin": null,
          "exchange": null, "initial_level": "256.26" }
      ],
      "observations": [
        { "obs_date": "2027-05-27", "pay_date": "2027-06-04", "coupon_rate_pct": null,
          "coupon_barrier_pct": null, "coupon_memory": false, "autocall_trigger_pct": "105",
          "autocall_amount_pct": "64" }
      ],
      "payout": [
        { "min_worst_pct": "100", "intercept_pct": "100", "slope": "0", "settlement": "cash", "description": "100%" },
        { "min_worst_pct": "45", "intercept_pct": "-45", "slope": "1", "settlement": "cash", "description": "100% + (WP − 145%)" },
        { "min_worst_pct": "0", "intercept_pct": "0", "slope": "0", "settlement": "cash", "description": "0%" }
      ]
    },
    "termsheet_path": "prf_…/3f2a….pdf",
    "termsheet_filename": "Example Step-Up Note Sept 26.PDF",
    "extracted_terms": { "…": "the model's raw answer, kept for audit" }
  },
  "warnings": ["MICROSOFT CORP: the sheet prints … Check the initial level."]
}
```

Errors: `422 NOT_A_TERM_SHEET`, `422 UNREADABLE` (a required field: currency, dates,
denomination, issue price, an underlying's initial level), `503 LLM_NOT_CONFIGURED`.

### Fields

- **underlyings**: `symbol` is the price feed's ticker (Yahoo Finance), derived from the
  Bloomberg code (`GOOGL UW` → `GOOGL`, `NESN SE` → `NESN.SW`); empty when unknown, with a
  warning. `initial_level` is the strike-date close in the share's currency.
- **observations**: one row per date, the coupon and autocall schedules merged. A coupon has a
  rate and a barrier (both or neither); `coupon_memory` pays the missed coupons too. An autocall
  has a trigger and an amount (both or neither). At least one of the two per row.
- **payout**: at the final valuation, WP is the worst share's close in % of its initial level.
  The branch with the highest `min_worst_pct` ≤ WP pays `greatest(0, intercept_pct + slope × WP)`
  % of the nominal; `physical` delivers shares of the worst underlying worth that at the final
  close (whole shares per note, the fraction in cash). A branch from `"0"` is required.
- **warnings** (the user checks them in the review): a printed absolute level that is not its
  percent of the initial level, half a coupon or autocall, dates out of order or outside the
  strike–final window, a duplicate date, no 0% branch, two branches at one level, a payout that
  falls as WP rises, and anything the model marked as not modelled (daily barriers, issuer calls,
  baskets that are not worst-of, quanto).

## `create_structured_note(p_profile_code, p_draft)`

`p_draft` is the response's `draft` with the user's corrections, plus:

```json
{
  "institution": "Swissquote",
  "notes": null,
  "investment": {
    "invested_amount": "5400.00",
    "purchase_price_pct": "54",
    "nominal": null,
    "trade_date": "2026-08-27",
    "funding_account_code": "acc_…"
  }
}
```

`purchase_price_pct` defaults to the issue price, `nominal` to `invested_amount / price × 100`,
`trade_date` to the issue date (else the strike date). `funding_account_code` (optional) is an
active current/savings account in the note's currency: the purchase is debited from it on the
trade date, and coupons and redemptions are credited to it on their payment dates.
`description` on a branch is for the review only and is not stored. Returns the holding code.
