// Pure parsers for the metal-prices function (unit-tested in _tests/metal_prices_test.ts).
//
// Gold is valued at the Dubai Jewellery Group's suggested retail rates (AED per gram, by karat),
// published on dubaicityofgold.com. Its admin-ajax endpoint returns the price list as HTML; the
// home page carries the same list, and Khaleej Times' gold page (whose JSON-LD carries the 24K
// rate) is the last resort. Silver is valued at Dubai's retail rate, from the same Khaleej Times
// JSON-LD (AED per kilo, from Al Kananah). Spot gold and silver are stored for reference:
// gold-api.com (USD per troy ounce, free, no key), else Swissquote's public quote feed (the mid
// of bid and ask). record_metal_prices converts USD/oz and AED/kg to AED/g in SQL; nothing here
// does arithmetic on money in floating point.

export const DJG_SOURCE = "dubaicityofgold.com";
export const DJG_AJAX_URL = "https://dubaicityofgold.com/wp-admin/admin-ajax.php";
export const DJG_HOME_URL = "https://dubaicityofgold.com/";
export const KT_SOURCE = "khaleejtimes.com";
export const KT_URL = "https://www.khaleejtimes.com/gold-forex";
export const GOLD_API_SOURCE = "gold-api.com";
export const SWISSQUOTE_SOURCE = "swissquote.com";

export type Metal = "XAU" | "XAG";
export const SPOT_QUOTE: Record<Metal, "gold_spot" | "silver_spot"> = { XAU: "gold_spot", XAG: "silver_spot" };

export function goldApiUrl(metal: Metal): string {
  return `https://api.gold-api.com/price/${metal}`;
}
export function swissquoteUrl(metal: Metal): string {
  return `https://forex-data-feed.swissquote.com/public-quotes/bboquotes/instrument/${metal}/USD`;
}

export interface MetalQuote {
  quote: string;
  aed_per_gram?: string;
  aed_per_kg?: string;
  usd_per_oz?: string;
  source: string;
}

const DECIMAL = /^\d+(?:\.\d+)?$/;
const KARATS: Record<string, string> = { "24": "gold_24k", "22": "gold_22k", "21": "gold_21k", "18": "gold_18k" };

/** A positive decimal string from a JSON number or string ("4,115.30" → "4115.30"); null otherwise. */
export function decimalText(v: unknown): string | null {
  if (typeof v === "number") {
    if (!Number.isFinite(v) || v <= 0) return null;
    v = String(v); // shortest round-trip text of the provider's own quote
  }
  if (typeof v !== "string") return null;
  const t = v.replace(/,/g, "").trim();
  if (!DECIMAL.test(t) || /^0+(\.0+)?$/.test(t)) return null;
  return t;
}

/** The DJG price list (HTML) → one quote per karat it shows. Throws without a 24K rate. */
export function parseDjgRates(html: string): MetalQuote[] {
  const out: MetalQuote[] = [];
  const seen = new Set<string>();
  const re = /(\d{2})K\s*Gold\s*<\/span>\s*<span[^>]*sortd-gold-value[^>]*>\s*AED\s*([\d,]+(?:\.\d+)?)\s*</gi;
  for (const m of html.matchAll(re)) {
    const quote = KARATS[m[1]];
    const price = decimalText(m[2]);
    if (!quote || !price || seen.has(quote)) continue;
    seen.add(quote);
    out.push({ quote, aed_per_gram: price, source: DJG_SOURCE });
  }
  if (!seen.has("gold_24k")) throw new Error("dubaicityofgold.com: no 24K rate in the price list");
  return out;
}

/** The admin-ajax response ({success, data: html}) → quotes. */
export function parseDjgAjax(body: unknown): MetalQuote[] {
  const b = body as { success?: unknown; data?: unknown } | null;
  if (b?.success !== true || typeof b.data !== "string") {
    throw new Error("dubaicityofgold.com: ajax answered without a price list");
  }
  return parseDjgRates(b.data);
}

/** gold-api.com /price/{XAU|XAG} → USD per troy ounce. */
export function parseGoldApi(body: unknown, metal: Metal): MetalQuote {
  const b = body as { symbol?: unknown; currency?: unknown; price?: unknown } | null;
  if (b?.symbol !== metal || b?.currency !== "USD") {
    throw new Error(`gold-api.com: expected ${metal} in USD, got ${String(b?.symbol)} in ${String(b?.currency)}`);
  }
  const usd = decimalText(b.price);
  if (!usd) throw new Error(`gold-api.com: ${metal} has no usable price`);
  return { quote: SPOT_QUOTE[metal], usd_per_oz: usd, source: GOLD_API_SOURCE };
}

/** The mid of two decimal strings, exact (BigInt), to at most 6 places. */
export function midDecimal(a: string, b: string): string {
  const places = Math.max(a.split(".")[1]?.length ?? 0, b.split(".")[1]?.length ?? 0);
  const scale = (s: string) => {
    const [i, f = ""] = s.split(".");
    return BigInt(i + f.padEnd(places, "0"));
  };
  const sum = scale(a) + scale(b); // mid = sum / 2, with one more place so .5 is exact
  const units = sum * 5n; // sum / 2 at places + 1
  const digits = units.toString().padStart(places + 2, "0");
  const text = `${digits.slice(0, -(places + 1))}.${digits.slice(-(places + 1))}`.replace(/\.?0+$/, "");
  return text === "" ? "0" : text;
}

/** Swissquote's public feed → the mid of the first platform's first spread profile. */
export function parseSwissquote(body: unknown, metal: Metal): MetalQuote {
  const platforms = Array.isArray(body) ? body : [];
  for (const p of platforms) {
    const prices = (p as { spreadProfilePrices?: unknown })?.spreadProfilePrices;
    if (!Array.isArray(prices)) continue;
    for (const sp of prices) {
      const bid = decimalText((sp as { bid?: unknown })?.bid);
      const ask = decimalText((sp as { ask?: unknown })?.ask);
      if (bid && ask) return { quote: SPOT_QUOTE[metal], usd_per_oz: midDecimal(bid, ask), source: SWISSQUOTE_SOURCE };
    }
  }
  throw new Error(`swissquote.com: no ${metal} bid and ask`);
}

/** Today's date in Dubai (YYYY-MM-DD), the date the DJG list is asked for. */
export function dubaiDate(now: Date = new Date()): string {
  return new Date(now.getTime() + 4 * 3600_000).toISOString().slice(0, 10);
}

/** Every schema.org ExchangeRateSpecification in a page's JSON-LD, as name → price text. */
export function jsonLdRates(html: string): Map<string, unknown> {
  const out = new Map<string, unknown>();
  const re = /<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  const walk = (o: unknown): void => {
    if (Array.isArray(o)) return o.forEach(walk);
    if (!o || typeof o !== "object") return;
    const r = o as Record<string, unknown>;
    if (r["@type"] === "ExchangeRateSpecification" && typeof r.name === "string") {
      const price = (r.currentExchangeRate as { price?: unknown } | undefined)?.price;
      if (!out.has(r.name)) out.set(r.name, price);
    }
    Object.values(r).forEach(walk);
  };
  for (const m of html.matchAll(re)) {
    try {
      walk(JSON.parse(m[1]));
    } catch {
      // another site's block that isn't JSON: skip it
    }
  }
  return out;
}

/** Khaleej Times' gold page → Dubai retail silver (AED per kilo) and the 24K gold rate. */
export function parseKhaleejTimes(html: string): { silver?: MetalQuote; gold24k?: MetalQuote } {
  const rates = jsonLdRates(html);
  const silverKg = decimalText(rates.get("Silver Rate (AED/Kilo)"));
  const gold = decimalText(rates.get("Gold Rate (AED/Gram)"));
  return {
    silver: silverKg ? { quote: "silver_retail", aed_per_kg: silverKg, source: KT_SOURCE } : undefined,
    gold24k: gold ? { quote: "gold_24k", aed_per_gram: gold, source: KT_SOURCE } : undefined,
  };
}
