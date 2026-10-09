# Plans

## 1. LLM categorisation: fewer re-asks, short refs, bigger batches (2026-10-09)

Context: prod has made 14 `llm_categorize` calls in total (~$0.02, Haiku 5.5); 234 profile×merchant
pairs reach the LLM. Goal is stability and quality more than spend. No schema change (functions only),
so no `pnpm db:types` drift.

- [x] **Migration `llm_categorize_tuning`** (`20261010001000`, commit 489b152) (`supabase migration new`):
  - [x] `private.enqueue_llm_categorize()`: batches of **100** (was 25).
  - [x] Re-ask rule: an existing `llm` suggestion made against an older category set is re-asked only when
        its category is archived, or was edited after the suggestion (`categories.updated_at >
        merchant_profile_category.updated_at`), or its confidence is < 0.8. Declined merchants are still
        re-asked on any category-set change (a new category may fit). Rejected: never (unchanged).
  - [x] `public.worker_llm_context`: examples are up to 3 **distinct** descriptions (distinct before
        limit; today `limit 3` then `distinct` often yields one), skipping ones equal to the name.
- [x] **Worker** (`supabase/functions/_shared/llm.ts`, `worker/llm_jobs.ts`):
  - [x] Prompt and schema use short refs `m1…mN` / `c1…cN` instead of 30-char codes; enums list the refs.
        `validateSuggestions` maps refs back to codes (unknown ref → dropped, as today).
  - [x] `processLlmCategorize`: accept up to 100 merchants (`slice(0, 100)`).
  - [x] Keep `effort: "low"`; leave thinking as is (optional follow-up: `thinking: disabled` after a
        quality check on a sample).
- [x] **Tests**: deno (`_tests/llm_jobs_test.ts`): ref round-trip, unknown/duplicate refs, 100-merchant
      batch. pgTAP: batch size, re-ask predicate (confident+unchanged → skipped; archived/edited/low
      confidence → queued), distinct examples.
- [x] **Verify**: `supabase db reset && supabase test db`; `cd supabase/functions && deno test -A .`;
      run the worker locally (`curl -s http://127.0.0.1:54321/functions/v1/worker` with `{"sync":true}`)
      against seed data and inspect `merchant_profile_category`; `pnpm check`.
- [x] **Docs**: CHANGELOG (Backend). ARCHITECTURE only if it states the batch size.
- [ ] **Deploy**: merge to `main` deploys the migration + `worker`; ask first (CLAUDE.md §11.2).

## 2. Category taxonomy v2 (`20261010001100`, commit c93956e)

Audit 2026-10-09 (prod, read-only). Top two categories per profile take 44% (P1: Shopping 27% +
Dining 18%) and 42% (P2: Transport 26% + Dining 17%); Utilities is 11–14% and mixes bills with
household services. Seed rules also misfile: `UBER` → Travel (rides and Uber Eats), `EMIRATES` → Travel
(Emirates Hospital, Emirates Leisure Retail, Emirates Fast Food), fees under Govt/Subscription/Investment.

Proposed spend categories (16 → 25; Cashback and Card Repayment unchanged):

| Today | Proposed |
|---|---|
| Dining | Restaurants & cafés · Food delivery |
| Shopping | Online marketplaces · Fashion · Home & furniture · Beauty & personal care · BNPL instalments |
| Transport | Rides & taxis · Fuel, charging & parking |
| Travel | Flights · Hotels & holidays |
| Utilities | Telecom & internet · Electricity, water & gas · Home services |
| Entertainment | Entertainment & activities (salons/spa → Beauty; Udemy → Education) |
| Fines/Govt Services | Government & fines (fees out) |
| Forex Charge + fees scattered elsewhere | Bank fees & interest |
| Medicine | Health & medical |
| Grocery, Subscription, Apple in-app purchase, Insurance, Investment, Donation, Fraud | unchanged |

Decided: both profiles; Forex Charge stays separate; BNPL and Education are their own categories;
Home & Furniture / Home Services / Hotels split dropped (too small). Al Jamea tus Saifiyah → Education.

- [x] Content migration (guarded, CLAUDE.md §1.9): new seed categories; per profile insert when absent;
      re-point/split seed rules only where they still hold the seeded pattern; fix the `UBER` /
      `EMIRATES` / fee rules; drop `llm` suggestions in split categories so the nightly job re-asks them
      (manual choices untouched). Depends on plan 1's re-ask rule.
- [x] pgTAP for the rule fixes; CHANGELOG; verify category shares on a prod-shaped local dump.
- [ ] Later (optional): roll analytics up by `parent_code` so charts can show ~10 groups with drill-down.

### Review (2026-10-09)
- Verified: deno 153 pass; pgTAP 883 pass from a fresh reset; worker run locally against Haiku 5.5
  (9 seed merchants, refs mapped back correctly); taxonomy replayed on 3,136 production descriptions
  (local copy of the old rules reproduced prod for 585/588 descriptions, then every move inspected).
- Backfill instead of tonight's Haiku run: 249 merchants on the LLM path classified in-session
  (59 moved, 17 left declined), applied via `apply_llm_suggestions` with the v2 category-set hash so
  `enqueue_llm_categorize` finds nothing. Script kept out of git (merchant codes).
- [ ] Push to main (deploys both migrations + worker), then run the backfill, then verify
      `needed_now = 0` and the new category shares in prod.
