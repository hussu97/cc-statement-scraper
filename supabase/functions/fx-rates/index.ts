// fx-rates: daily market FX rates → public.fx_rates. pg_cron calls it at 21:00 UTC
// with x-cron-secret (job `ledger-fx-rates`).
//
// Rates come from open.er-api.com (free, no key), quoted per 1 AED and inverted to
// AED per unit in ./rates.ts. upsert_fx_rates stores them and re-estimates pending
// SMS transactions, so currencies never seen on a statement (EGP, INR, …) still get
// an estimated AED amount. Any failure throws, so Sentry captures it.

import { withSentry } from "../_shared/sentry.ts";
import { requireCron } from "../_shared/auth.ts";
import { pgErrorToHttp, requireMethod } from "../_shared/http.ts";
import { runCronJob } from "../_shared/cron.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { type ErApiLatest, FX_URL, parseErApi } from "./rates.ts";

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);
  return await runCronJob(req, "fx-rates", refreshRates);
}

async function refreshRates() {
  const res = await fetch(FX_URL, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(15_000) });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`fx provider HTTP ${res.status}`);
  }
  const update = parseErApi((await res.json()) as ErApiLatest);
  const { data, error } = await serviceClient().rpc("upsert_fx_rates", {
    p_rates: update.rates,
    p_source: update.source,
    p_as_of: update.asOf,
  });
  if (error) throw pgErrorToHttp(error, "upsert_fx_rates failed");
  return { as_of: update.asOf, source: update.source, currencies: Object.keys(update.rates).length, result: data };
}

Deno.serve(withSentry("fx-rates", handler));
