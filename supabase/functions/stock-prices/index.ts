// stock-prices: daily closes of every share a structured note follows (and shares a note
// delivered) → public.security_prices, then settles the notes (private.settle_structured_note:
// coupons, autocalls and maturities onto the funding account).
//
// Callers:
//   * pg_cron with x-cron-secret (job `ledger-stock-prices`, 30 22 * * 1-6 UTC, after the US
//     close): every symbol, from 5 days before its last stored close (a corrected close is
//     replaced), or from 7 days before a note's strike when the stored closes start later.
//   * a ledger owner (user JWT, body {"profile_code"}): right after adding a note, so its past
//     observations have closes. Runs synchronously and returns what was stored.
// Source: Yahoo Finance's chart endpoint (./yahoo.ts); query2 when query1 refuses.

import { withSentry } from "../_shared/sentry.ts";
import { assertOwner, requireCron, requireUser } from "../_shared/auth.ts";
import { HttpError, json, pgErrorToHttp, readJson, requireMethod } from "../_shared/http.ts";
import { runCronJob } from "../_shared/cron.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { chartHosts, chartUrl, type Close, fetchFrom, parseChart, type PriceSymbol } from "./yahoo.ts";

const UA = "Mozilla/5.0 (compatible; BankLedger/1.0; +https://cc-statement-scraper.vercel.app)";

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  if (req.headers.get("x-cron-secret")) {
    await requireCron(req);
    return await runCronJob(req, "stock-prices", () => refresh(null));
  }
  const caller = await requireUser(req);
  const body = (await readJson(req)) as { profile_code?: unknown } | null;
  const profileCode = typeof body?.profile_code === "string" ? body.profile_code : "";
  if (!/^prf_[0-9a-z]{26}$/.test(profileCode)) throw new HttpError(400, "BAD_REQUEST", "profile_code required");
  await assertOwner(caller, profileCode);
  return json(await refresh(profileCode), 200, req);
}

async function fetchCloses(symbol: string, from: Date, to: Date): Promise<Close[]> {
  const errors: string[] = [];
  for (const host of chartHosts) {
    const res = await fetch(chartUrl(symbol, from, to, host), {
      headers: { accept: "application/json", "user-agent": UA },
      signal: AbortSignal.timeout(15_000),
    });
    if (res.ok) return parseChart(await res.json(), symbol);
    await res.body?.cancel();
    errors.push(`${host} HTTP ${res.status}`);
    if (res.status === 404) break; // an unknown symbol is unknown on both hosts
  }
  throw new Error(`${symbol}: ${errors.join(", ")}`);
}

async function refresh(profileCode: string | null) {
  const db = serviceClient();
  const { data, error } = await db.rpc("price_symbols", { p_profile_code: profileCode });
  if (error) throw pgErrorToHttp(error, "price_symbols failed");
  const symbols = (data ?? []) as PriceSymbol[];
  const now = new Date();
  const errors: string[] = [];
  const rows: Close[] = [];
  // A handful of symbols: one at a time keeps well under Yahoo's rate limit.
  for (const s of symbols) {
    const from = fetchFrom(s);
    try {
      rows.push(...await fetchCloses(s.symbol, from, now));
    } catch (e) {
      errors.push(String(e instanceof Error ? e.message : e));
    }
  }
  let stored = 0;
  if (rows.length > 0) {
    const { data: n, error: e } = await db.rpc("record_security_prices", { p_rows: rows, p_source: "yahoo" });
    if (e) throw pgErrorToHttp(e, "record_security_prices failed");
    stored = n as number;
  }
  const { data: settled, error: se } = await db.rpc("settle_structured_notes");
  if (se) throw pgErrorToHttp(se, "settle_structured_notes failed");
  const result = { symbols: symbols.length, stored, settled, failed: errors };
  // The cron run reports a symbol it could not price; a user's backfill returns it instead.
  if (errors.length > 0 && profileCode === null) throw new Error(`stock-prices: ${errors.join(" | ")}`);
  return result;
}

Deno.serve(withSentry("stock-prices", handler));
