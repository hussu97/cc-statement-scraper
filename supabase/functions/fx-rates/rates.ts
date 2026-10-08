// Pure FX-rate conversion for the fx-rates function (unit-tested in _tests/fx_rates_test.ts).
//
// open.er-api.com/v6/latest/AED quotes "units of X per 1 AED". The ledger stores
// "AED per 1 unit of X" (public.fx_rates.aed_per_unit, numeric(18,8)), so each
// quote is inverted. The division is done in decimal (BigInt), never in float,
// and the result is a decimal string rounded half-up to 8 places.

export const FX_SOURCE = "open.er-api.com";
export const FX_URL = "https://open.er-api.com/v6/latest/AED";

const CURRENCY = /^[A-Z]{3}$/;
const DECIMAL = /^(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?$/i;
const SCALE = 8;
const MAX_UNITS = 10n ** 18n; // numeric(18,8): at most 10 integer digits

/** 1 / quote, as a decimal string with 8 places; null if not positive or out of numeric(18,8) range. */
export function invertRate(quote: number | string): string | null {
  const text = typeof quote === "number" ? (Number.isFinite(quote) ? String(quote) : "") : quote.trim();
  const m = DECIMAL.exec(text);
  if (!m) return null;
  const frac = m[2] ?? "";
  const mantissa = BigInt(m[1] + frac);
  if (mantissa === 0n) return null;
  // quote = mantissa / 10^scale  →  10^8 / quote = 10^(scale + 8) / mantissa
  const exp = frac.length - Number(m[3] ?? 0) + SCALE;
  if (exp < 0) return null; // inverse < 10^-8
  const numerator = 10n ** BigInt(exp);
  const units = (2n * numerator + mantissa) / (2n * mantissa); // round half-up
  if (units === 0n || units >= MAX_UNITS) return null;
  const digits = units.toString().padStart(SCALE + 1, "0");
  return `${digits.slice(0, -SCALE)}.${digits.slice(-SCALE)}`;
}

/** Keep ISO-like 3-letter codes with a usable quote; map each to AED per unit. */
export function aedPerUnit(rates: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [code, quote] of Object.entries(rates)) {
    if (!CURRENCY.test(code)) continue;
    if (typeof quote !== "number" && typeof quote !== "string") continue;
    const inverted = invertRate(quote);
    if (inverted !== null) out[code] = inverted;
  }
  return out;
}

export interface ErApiLatest {
  result?: unknown;
  base_code?: unknown;
  time_last_update_unix?: unknown;
  rates?: unknown;
  "error-type"?: unknown;
}

export interface FxRatesUpdate {
  rates: Record<string, string>;
  source: string;
  asOf: string; // YYYY-MM-DD (UTC date of the provider's last update)
}

/** Validate an open.er-api.com response and turn it into an upsert_fx_rates payload. Throws on anything unusable. */
export function parseErApi(body: ErApiLatest, now: Date = new Date()): FxRatesUpdate {
  if (body?.result !== "success") {
    throw new Error(
      `fx provider returned result=${String(body?.result)} (${String(body?.["error-type"] ?? "no error type")})`,
    );
  }
  if (body.base_code !== "AED") throw new Error(`fx provider base is ${String(body.base_code)}, expected AED`);
  if (!body.rates || typeof body.rates !== "object" || Array.isArray(body.rates)) {
    throw new Error("fx provider response has no rates object");
  }
  const rates = aedPerUnit(body.rates as Record<string, unknown>);
  if (Object.keys(rates).length === 0) throw new Error("fx provider returned no usable rates");
  const unix = typeof body.time_last_update_unix === "number" ? body.time_last_update_unix : NaN;
  const asOf = (Number.isFinite(unix) ? new Date(unix * 1000) : now).toISOString().slice(0, 10);
  return { rates, source: FX_SOURCE, asOf };
}
