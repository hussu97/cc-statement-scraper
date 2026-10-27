// Reading a structured note's term sheet (contract: docs/contracts/termsheet-v1.md). Pure:
// the model's JSON schema and instructions, and the normalisation and checks that turn its
// answer into the draft create_structured_note takes. Tested in _tests/termsheet_test.ts.

import { bloombergToYahoo } from "../stock-prices/yahoo.ts";

export const DEFAULT_TERMSHEET_MODEL = "claude-sonnet-5-5";

export function termsheetModel(): string {
  return Deno.env.get("TERMSHEET_LLM_MODEL") || DEFAULT_TERMSHEET_MODEL;
}

const str = { type: "string" };
const nstr = { type: ["string", "null"] };
const obj = (properties: Record<string, unknown>) => ({
  type: "object",
  properties,
  required: Object.keys(properties),
  additionalProperties: false,
});

/** What the model fills in. Numbers are decimal strings; dates YYYY-MM-DD; % are percent (98 = 98%). */
export const TERMSHEET_SCHEMA: Record<string, unknown> = obj({
  is_term_sheet: { type: "boolean" },
  short_name: str,
  product_name: str,
  isin: nstr,
  issuer: nstr,
  guarantor: nstr,
  currency: str,
  denomination: str,
  issue_price_pct: str,
  strike_date: str,
  issue_date: nstr,
  final_valuation_date: str,
  maturity_date: str,
  underlyings: {
    type: "array",
    items: obj({
      name: str,
      bloomberg_code: nstr,
      isin: nstr,
      exchange: nstr,
      initial_level: str,
      printed_levels: { type: "array", items: obj({ label: str, pct: str, value: str }) },
    }),
  },
  observations: {
    type: "array",
    items: obj({
      obs_date: str,
      pay_date: str,
      coupon_rate_pct: nstr,
      coupon_barrier_pct: nstr,
      coupon_memory: { type: "boolean" },
      autocall_trigger_pct: nstr,
      autocall_amount_pct: nstr,
    }),
  },
  payout: {
    type: "array",
    items: obj({
      min_worst_pct: str,
      intercept_pct: str,
      slope: str,
      settlement: { type: "string", enum: ["cash", "physical"] },
      description: str,
    }),
  },
  unsupported: { type: "array", items: str },
});

export const TERMSHEET_SYSTEM = [
  "You read the term sheet of a structured note (an equity-linked autocallable, Phoenix, Athena,",
  "reverse convertible, ...) and transcribe its terms exactly. Never invent a value: copy numbers and",
  "dates as printed, converted to the formats below. If the document is not a structured-note term",
  "sheet, set is_term_sheet false and fill the rest with empty values.",
  "",
  "Formats: dates YYYY-MM-DD. Numbers as decimal strings without separators or units. Percentages",
  'as percent numbers: 98% → "98", 0.667% → "0.667". Levels are percent of each underlying\'s',
  "initial level; amounts are percent of the denomination (nominal).",
  "",
  "short_name: at most 60 characters, issuer + structure + tickers + maturity year,",
  'e.g. "Example Bank A Phoenix AMZN/META/ORCL 2029".',
  "currency / denomination: the settlement currency and the denomination (calculation amount, or",
  "the notional per certificate). issue_price_pct: the issue price in % of denomination.",
  "strike_date: the initial fixing / strike / trade date that fixed the initial levels.",
  "final_valuation_date: the final fixing / redemption valuation date. maturity_date: the",
  "redemption / maturity date.",
  "",
  "underlyings: one per share, in the sheet's order. initial_level: the initial fixing / RI initial",
  'value / Share initial, in the share\'s currency. bloomberg_code as printed (e.g. "GOOGL UW Equity").',
  "printed_levels: every other absolute level printed for that share with its percent (barrier,",
  "strike, coupon barrier, autocall trigger, knock-in): {label, pct, value}.",
  "",
  "observations: ONE row per observation date, merging the coupon schedule and the early-redemption",
  "(autocall) schedule by date; ascending. pay_date: the matching coupon payment / early redemption",
  "date. coupon_rate_pct: the coupon for that date (per period, not per annum) or null when no coupon",
  "is observed that date. coupon_barrier_pct: the level the worst share must be at or above for that",
  "coupon (0 if unconditional); null when no coupon. coupon_memory: true when a missed coupon is paid",
  'later ("memory", "sum of coupon rates minus previously paid", "Rate + Sum Rate").',
  "autocall_trigger_pct: the autocall / early-redemption trigger level that date (a level given as",
  "a price per share, e.g. 105% × initial, is 105) or null when no early redemption is observed.",
  "autocall_amount_pct: what is repaid on autocall that date in % of denomination (compute formulas",
  "such as 63% + n × 1% for each row); null when no autocall. Include the final valuation date as a",
  "row only if the sheet lists a coupon or an early redemption on it.",
  "",
  "payout: the redemption at maturity when the note was not called, as branches on WP, the worst",
  "share's final level in % of its initial level. Each branch applies from min_worst_pct (inclusive)",
  "up to the next higher branch and pays greatest(0, intercept_pct + slope × WP) % of denomination.",
  'Always include a branch with min_worst_pct "0". settlement: physical when shares of the worst',
  "share are delivered (their value at the final close is what the branch pays), else cash.",
  "Examples:",
  "- WP ≥ 100% → 100%, else shares worth Denomination × (WP − 24.5%): [{100, 100, 0, cash},",
  "  {0, -24.5, 1, physical}].",
  "- WP ≥ 60% → 100%, else Calculation Amount / (60% × initial) shares: worth WP / 0.6:",
  "  [{60, 100, 0, cash}, {0, 0, 1.66666667, physical}].",
  "- WP ≥ 100% → 181%; below 100% without knock-in (WP ≥ 63.5%) → 100%; knock-in → WP:",
  "  [{100, 181, 0, cash}, {63.5, 100, 0, cash}, {0, 0, 1, cash}].",
  "- WP ≥ 100% → 100%; WP ≥ 45% → 100% + (WP − 145%) = WP − 45%; else 0:",
  "  [{100, 100, 0, cash}, {45, -45, 1, cash}, {0, 0, 0, cash}].",
  "description: the branch in a few words as the sheet states it.",
  "",
  "unsupported: only a term that changes what is paid and that these fields cannot express, in a",
  "short sentence each: a barrier observed daily or continuously, an issuer call, a coupon not tied",
  "to the worst share, a basket average instead of worst-of, quanto or FX conversion. Never list what",
  "the fields already express: an issue price below 100%, memory coupons, an autocall or coupon that",
  "needs every share at or above a level, physical delivery rounded to whole shares with a cash",
  "residual, the calculation agent choosing between tied shares. Usually empty.",
].join("\n");

// ── normalisation ───────────────────────────────────────────────────────────

export interface DraftUnderlying {
  name: string;
  symbol: string;
  bloomberg_code: string | null;
  isin: string | null;
  exchange: string | null;
  initial_level: string;
}

export interface DraftObservation {
  obs_date: string;
  pay_date: string;
  coupon_rate_pct: string | null;
  coupon_barrier_pct: string | null;
  coupon_memory: boolean;
  autocall_trigger_pct: string | null;
  autocall_amount_pct: string | null;
}

export interface DraftBranch {
  min_worst_pct: string;
  intercept_pct: string;
  slope: string;
  settlement: "cash" | "physical";
  description: string;
}

export interface DraftTerms {
  product_name: string;
  isin: string | null;
  issuer: string | null;
  guarantor: string | null;
  currency: string;
  denomination: string;
  issue_price_pct: string;
  strike_date: string;
  issue_date: string | null;
  final_valuation_date: string;
  maturity_date: string;
  underlyings: DraftUnderlying[];
  observations: DraftObservation[];
  payout: DraftBranch[];
}

export interface Extraction {
  name: string;
  terms: DraftTerms;
  warnings: string[];
}

export class NotATermSheet extends Error {
  constructor() {
    super("this PDF is not a structured-note term sheet");
    this.name = "NotATermSheet";
  }
}

/** "1,234.50" / "98%" / " 0.667 " → "1234.50" / "98" / "0.667"; null when not a number. */
export function decimal(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim().replace(/[,%\s]/g, "").replace(/^USD|^EUR|^CHF|^GBP/i, "");
  if (!/^-?[0-9]+(?:\.[0-9]+)?$/.test(s)) return null;
  const [i, f] = s.split(".");
  const int = i.replace(/^(-?)0+(?=\d)/, "$1");
  const frac = (f ?? "").replace(/0+$/, "");
  return frac ? `${int}.${frac}` : int;
}

function isoDate(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const d = new Date(`${s}T00:00:00Z`);
  return Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== s ? null : s;
}

function text(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const s = v.replace(/\s+/g, " ").trim();
  return s ? s.slice(0, max) : null;
}

const ISIN = /^[A-Z]{2}[A-Z0-9]{9}[0-9]$/;

function isin(v: unknown): string | null {
  const s = typeof v === "string" ? v.replace(/\s/g, "").toUpperCase() : "";
  return ISIN.test(s) ? s : null;
}

/** greatest(0, intercept + slope × wp) of the branch that applies. */
export function payoutAt(branches: DraftBranch[], wp: number): number | null {
  const b = branches
    .filter((x) => Number(x.min_worst_pct) <= wp)
    .sort((a, c) => Number(c.min_worst_pct) - Number(a.min_worst_pct))[0];
  return b ? Math.max(0, Number(b.intercept_pct) + Number(b.slope) * wp) : null;
}

/**
 * The model's answer → the draft terms and what the user should check. Throws NotATermSheet,
 * or Error with our own text when a required field is missing; never echoes document text.
 */
export function normalizeExtraction(raw: unknown): Extraction {
  if (!raw || typeof raw !== "object") throw new Error("extraction is not an object");
  const r = raw as Record<string, unknown>;
  if (r.is_term_sheet === false) throw new NotATermSheet();
  const warnings: string[] = [];
  const need = <T>(v: T | null, what: string): T => {
    if (v === null) throw new Error(`the term sheet's ${what} could not be read`);
    return v;
  };

  const currency = need(text(r.currency, 3)?.toUpperCase() ?? null, "currency");
  if (!/^[A-Z]{3}$/.test(currency)) throw new Error("the term sheet's currency could not be read");
  const strike = need(isoDate(r.strike_date), "strike date");
  const finalDate = need(isoDate(r.final_valuation_date), "final valuation date");
  const maturity = need(isoDate(r.maturity_date), "maturity date");
  const issueDate = isoDate(r.issue_date);

  const underlyings: DraftUnderlying[] = [];
  for (const [i, u] of ((r.underlyings ?? []) as Record<string, unknown>[]).entries()) {
    const name = text(u.name, 120) ?? `Underlying ${i + 1}`;
    const initial = decimal(u.initial_level);
    if (!initial || Number(initial) <= 0) throw new Error(`the initial level of ${name} could not be read`);
    const bbg = text(u.bloomberg_code, 40);
    const symbol = bbg ? bloombergToYahoo(bbg) : null;
    if (!symbol) warnings.push(`Set the price symbol for ${name}: no ticker could be derived.`);
    for (const p of (u.printed_levels ?? []) as Record<string, unknown>[]) {
      const pct = Number(decimal(p.pct));
      const value = Number(decimal(p.value));
      if (!Number.isFinite(pct) || !Number.isFinite(value) || pct <= 0 || value <= 0) continue;
      const expected = Number(initial) * pct / 100;
      if (Math.abs(expected - value) > Math.max(0.01, expected * 0.0005)) {
        warnings.push(
          `${name}: the sheet prints ${text(p.label, 40) ?? "a level"} ${value} for ${pct}%, but ${pct}% of the ` +
            `initial ${initial} is ${expected.toFixed(4)}. Check the initial level.`,
        );
      }
    }
    underlyings.push({
      name,
      symbol: symbol ?? "",
      bloomberg_code: bbg,
      isin: isin(u.isin),
      exchange: text(u.exchange, 80),
      initial_level: initial,
    });
  }
  if (underlyings.length === 0) throw new Error("no underlying could be read");

  const observations: DraftObservation[] = [];
  for (const o of (r.observations ?? []) as Record<string, unknown>[]) {
    const obs = isoDate(o.obs_date);
    const pay = isoDate(o.pay_date);
    if (!obs || !pay) {
      warnings.push("An observation row without a readable date was left out.");
      continue;
    }
    let rate = decimal(o.coupon_rate_pct);
    let barrier = decimal(o.coupon_barrier_pct);
    if ((rate === null) !== (barrier === null)) {
      warnings.push(`${obs}: a coupon needs both a rate and a barrier; the coupon was left out.`);
      rate = barrier = null;
    }
    let trigger = decimal(o.autocall_trigger_pct);
    let amount = decimal(o.autocall_amount_pct);
    if ((trigger === null) !== (amount === null)) {
      warnings.push(`${obs}: an autocall needs both a trigger and an amount; the autocall was left out.`);
      trigger = amount = null;
    }
    if (rate === null && trigger === null) continue;
    observations.push({
      obs_date: obs,
      pay_date: pay,
      coupon_rate_pct: rate,
      coupon_barrier_pct: barrier,
      coupon_memory: rate !== null && o.coupon_memory === true,
      autocall_trigger_pct: trigger,
      autocall_amount_pct: amount,
    });
  }
  observations.sort((a, b) => a.obs_date.localeCompare(b.obs_date));
  for (let i = 1; i < observations.length; i++) {
    if (observations[i].obs_date === observations[i - 1].obs_date) {
      warnings.push(`${observations[i].obs_date} appears twice in the schedule.`);
    }
  }
  for (const o of observations) {
    if (o.pay_date < o.obs_date) warnings.push(`${o.obs_date}: paid before it is observed (${o.pay_date}).`);
    if (o.obs_date < strike || o.obs_date > finalDate) {
      warnings.push(`${o.obs_date} falls outside the strike date and the final valuation.`);
    }
  }

  const payout: DraftBranch[] = [];
  for (const b of (r.payout ?? []) as Record<string, unknown>[]) {
    const min = decimal(b.min_worst_pct);
    const intercept = decimal(b.intercept_pct);
    const slope = decimal(b.slope);
    if (min === null || intercept === null || slope === null || Number(slope) < 0 || Number(min) < 0) {
      warnings.push("A payout branch that could not be read was left out.");
      continue;
    }
    payout.push({
      min_worst_pct: min,
      intercept_pct: intercept,
      slope,
      settlement: b.settlement === "physical" ? "physical" : "cash",
      description: text(b.description, 200) ?? "",
    });
  }
  payout.sort((a, b) => Number(b.min_worst_pct) - Number(a.min_worst_pct));
  if (!payout.some((b) => Number(b.min_worst_pct) === 0)) {
    warnings.push("The payout has no branch from 0%: add what is paid however far the worst share falls.");
  }
  if (new Set(payout.map((b) => Number(b.min_worst_pct))).size !== payout.length) {
    warnings.push("Two payout branches start at the same level.");
  }
  // A payout that falls as the worst share rises is almost always a misread branch.
  let prev = -Infinity;
  for (let wp = 0; wp <= 200; wp += 0.5) {
    const p = payoutAt(payout, wp);
    if (p !== null && p < prev - 1e-9) {
      warnings.push(`The payout falls as the worst share rises (at ${wp}%): check the branches.`);
      break;
    }
    if (p !== null) prev = p;
  }

  if (strike > finalDate || finalDate > maturity) {
    warnings.push("The strike, final valuation and maturity dates are out of order.");
  }
  for (const u of r.unsupported as unknown[] ?? []) {
    const t = text(u, 200);
    if (t) warnings.push(`Not modelled: ${t}`);
  }

  const denomination = need(decimal(r.denomination), "denomination");
  const issuePrice = need(decimal(r.issue_price_pct), "issue price");
  const productName = text(r.product_name, 300) ?? "Structured note";
  return {
    name: text(r.short_name, 80) ?? productName.slice(0, 80),
    terms: {
      product_name: productName,
      isin: isin(r.isin),
      issuer: text(r.issuer, 120),
      guarantor: text(r.guarantor, 120),
      currency,
      denomination,
      issue_price_pct: issuePrice,
      strike_date: strike,
      issue_date: issueDate,
      final_valuation_date: finalDate,
      maturity_date: maturity,
      underlyings,
      observations,
      payout,
    },
    warnings,
  };
}
