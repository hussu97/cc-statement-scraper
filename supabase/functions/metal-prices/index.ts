// metal-prices: gold and silver prices → public.metal_prices. pg_cron calls it every 6 hours
// with x-cron-secret (job `ledger-metal-prices`, 7 */6 * * * UTC).
//
// Gold: the Dubai Jewellery Group's retail rates by karat (dubaicityofgold.com, the ajax list,
// else the home page, else Khaleej Times' 24K rate). Silver: Dubai retail per kilo from Khaleej
// Times. Spot gold and silver, for reference: gold-api.com, else Swissquote's public feed (see
// ./quotes.ts). Whatever was fetched is stored through record_metal_prices; then any source
// that failed, or a price the database refused, throws so Sentry captures it.

import { withSentry } from "../_shared/sentry.ts";
import { requireCron } from "../_shared/auth.ts";
import { pgErrorToHttp, requireMethod } from "../_shared/http.ts";
import { runCronJob } from "../_shared/cron.ts";
import { serviceClient } from "../_shared/supabase.ts";
import {
  DJG_AJAX_URL,
  DJG_HOME_URL,
  dubaiDate,
  goldApiUrl,
  KT_URL,
  type Metal,
  type MetalQuote,
  parseDjgAjax,
  parseDjgRates,
  parseGoldApi,
  parseKhaleejTimes,
  parseSwissquote,
  swissquoteUrl,
} from "./quotes.ts";

const UA = "Mozilla/5.0 (compatible; BankLedger/1.0; +https://cc-statement-scraper.vercel.app)";

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);
  return await runCronJob(req, "metal-prices", refreshPrices);
}

async function fetchJson(url: string, init: RequestInit = {}): Promise<unknown> {
  const res = await fetch(url, {
    ...init,
    headers: { accept: "application/json", "user-agent": UA, ...(init.headers ?? {}) },
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`${new URL(url).host} HTTP ${res.status}`);
  }
  return await res.json();
}

async function fetchText(url: string): Promise<string> {
  const res = await fetch(url, { headers: { "user-agent": UA }, signal: AbortSignal.timeout(15_000) });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`${new URL(url).host} HTTP ${res.status}`);
  }
  return await res.text();
}

async function retailGold(kt: Promise<ReturnType<typeof parseKhaleejTimes>>): Promise<MetalQuote[]> {
  try {
    return parseDjgAjax(
      await fetchJson(DJG_AJAX_URL, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: `action=sortd_gold_price&date=${dubaiDate()}`,
      }),
    );
  } catch (ajaxError) {
    try {
      return parseDjgRates(await fetchText(DJG_HOME_URL));
    } catch (homeError) {
      const gold24k = (await kt.catch(() => ({ gold24k: undefined }))).gold24k;
      if (gold24k) return [gold24k];
      throw new Error(`gold retail: ${String(ajaxError)}; ${String(homeError)}; no 24K rate on khaleejtimes.com`);
    }
  }
}

async function retailSilver(kt: Promise<ReturnType<typeof parseKhaleejTimes>>): Promise<MetalQuote> {
  const { silver } = await kt;
  if (!silver) throw new Error("khaleejtimes.com: no Silver Rate (AED/Kilo) in the page's JSON-LD");
  return silver;
}

async function spot(metal: Metal): Promise<MetalQuote> {
  try {
    return parseGoldApi(await fetchJson(goldApiUrl(metal)), metal);
  } catch (primary) {
    try {
      return parseSwissquote(await fetchJson(swissquoteUrl(metal)), metal);
    } catch (fallback) {
      throw new Error(`${metal} spot: ${String(primary)}; ${String(fallback)}`);
    }
  }
}

async function refreshPrices() {
  const asOf = new Date().toISOString();
  const kt = fetchText(KT_URL).then(parseKhaleejTimes);
  kt.catch(() => {}); // awaited below; never an unhandled rejection
  const results = await Promise.allSettled([retailGold(kt), retailSilver(kt), spot("XAU"), spot("XAG")]);
  const quotes: MetalQuote[] = [];
  const errors: string[] = [];
  for (const r of results) {
    if (r.status === "fulfilled") quotes.push(...[r.value].flat());
    else errors.push(String(r.reason));
  }
  let stored: unknown = [];
  let rejected: { quote?: string; reason?: string }[] = [];
  if (quotes.length > 0) {
    const { data, error } = await serviceClient().rpc("record_metal_prices", {
      p_quotes: quotes.map((q) => ({ ...q, as_of: asOf })),
    });
    if (error) throw pgErrorToHttp(error, "record_metal_prices failed");
    const result = data as { stored?: unknown; rejected?: { quote?: string; reason?: string }[] };
    stored = result.stored ?? [];
    rejected = result.rejected ?? [];
  }
  for (const r of rejected) errors.push(`${r.quote}: ${r.reason}`);
  if (errors.length > 0) throw new Error(`metal-prices: ${errors.join(" | ")} (stored ${JSON.stringify(stored)})`);
  return { as_of: asOf, stored };
}

Deno.serve(withSentry("metal-prices", handler));
