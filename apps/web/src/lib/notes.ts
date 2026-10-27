// Structured notes (Wealth → Investments): wording and form plumbing for what the server sends.
// Every figure (coupons, redemptions, distances, payouts, scenarios) is computed by
// private.note_evaluate (CLAUDE.md §2.2); these helpers only word it, and check and shape what
// the user types into the termsheet-v1 draft (docs/contracts/termsheet-v1.md). Pure, unit-tested.
import { formatDate } from "./dates";
import { trimDecimal } from "./holdings";

// ── statuses and outcomes ──────────────────────────────────────────────────

export type NoteStatus = "live" | "awaiting_strike" | "autocalled" | "matured" | "cancelled";

export const NOTE_STATUS: Record<NoteStatus, { label: string; tone: "accent" | "positive" | "neutral" | "warn" }> = {
  live: { label: "Live", tone: "accent" },
  awaiting_strike: { label: "Not struck yet", tone: "neutral" },
  autocalled: { label: "Called early", tone: "positive" },
  matured: { label: "Matured", tone: "neutral" },
  cancelled: { label: "Cancelled", tone: "warn" },
};

export function noteStatus(s: string | null | undefined): { label: string; tone: "accent" | "positive" | "neutral" | "warn" } {
  return NOTE_STATUS[(s ?? "live") as NoteStatus] ?? NOTE_STATUS.live;
}

export function isEnded(s: string | null | undefined): boolean {
  return s === "autocalled" || s === "matured" || s === "cancelled";
}

/** "98" → "98%", "0.667" → "0.667%"; with `digits`, rounded to at most that many places ("91.4655", 2 → "91.47%"). "—" when absent. */
export function pct(v: string | null | undefined, digits?: number): string {
  let s = (v ?? "").trim();
  if (digits !== undefined && s !== "" && Number.isFinite(Number(s))) s = Number(s).toFixed(digits);
  const negative = s.startsWith("-");
  const t = trimDecimal(negative ? s.slice(1) : s);
  return t ? `${negative ? "−" : ""}${t}%` : "—";
}

/**
 * How far a share is from a level, in words: "needs +7.46%" when it must rise to reach it,
 * "7.46% above" when it can fall that far and still be at it, "at the level" at 0.
 */
export function distanceText(distancePct: string | null | undefined): string {
  const n = distancePct === null || distancePct === undefined ? NaN : Number(distancePct);
  if (!Number.isFinite(n)) return "—";
  if (n === 0) return "at the level";
  const abs = trimDecimal(String(Math.abs(n)));
  return n > 0 ? `needs +${abs}%` : `${abs}% above`;
}

/** Above (or at) a level means the condition holds today. */
export function distanceMet(distancePct: string | null | undefined): boolean {
  const n = Number(distancePct);
  return Number.isFinite(n) && n <= 0;
}

export const LEVEL_LABEL: Record<string, string> = {
  autocall: "Autocall",
  coupon: "Coupon barrier",
  final: "At maturity",
  break_even: "Break-even at maturity",
};

/** A level's label: a final branch says what it pays ("At maturity: 100%" / "… shares"). */
export function levelLabel(l: { kind: string; payout_pct?: string | null; settlement?: string | null }): string {
  if (l.kind === "final") {
    const pays = l.payout_pct ? pct(l.payout_pct) : "—";
    return `At maturity ≥ this: ${pays}${l.settlement === "physical" ? " in shares" : ""}`;
  }
  return LEVEL_LABEL[l.kind] ?? l.kind;
}

export const OUTCOME_LABEL: Record<string, string> = {
  coupon: "Coupon paid",
  coupon_missed: "Coupon missed",
  autocall: "Called early",
  autocall_missed: "Not called",
  maturity: "Redeemed",
  // A coupon paid before the note was bought: it belonged to the seller.
  coupon_before_purchase: "Before purchase",
};

/** An outcome or event kind in words; a kind this build doesn't know reads as its words ("some_kind" → "Some kind"), never blank. */
export function outcomeLabel(kind: string | null | undefined): string {
  const k = kind ?? "";
  if (OUTCOME_LABEL[k]) return OUTCOME_LABEL[k];
  const words = k.replace(/_/g, " ").trim();
  return words ? words.charAt(0).toUpperCase() + words.slice(1) : "Outcome";
}

/** How an outcome reads: a coupon paid or a call is good news; everything else (missed, maturity, before purchase, unknown) is muted. */
export function outcomeTone(kind: string | null | undefined): "positive" | "muted" {
  return kind === "coupon" || kind === "autocall" ? "positive" : "muted";
}

// ── sell today or wait for the call ───────────────────────────────────────

/** The first autocall still ahead, as the server prices it (private.note_evaluate's if_called_next). */
export interface CallScenario {
  obs_date: string;
  pay_date: string;
  trigger_pct: string;
  redemption_pct: string;
  redemption: string;
  coupons: string;
  total: string;
  profit: string;
  return_pct: string;
  annualised_pct: string | null;
}

/** What the note fetches sold today at the broker's bid (structured_notes_summary's `market`). */
export interface MarketQuote {
  price_pct: string | null;
  value: string;
  as_of: string | null;
  profit: string;
}

export interface SellToday {
  total: string;
  profit: string;
  returnPct: string | null;
  /** The bid as % of nominal, when the price is quoted that way. */
  pricePct: string | null;
  asOf: string | null;
}

export interface IfCalled {
  obsDate: string;
  payDate: string;
  total: string;
  profit: string;
  returnPct: string | null;
  annualisedPct: string | null;
  triggerPct: string | null;
}

/** A note's market quote as "sell today"; null without one. */
export function sellFromMarket(m: MarketQuote | null | undefined): SellToday | null {
  if (!m || m.value === null || m.value === undefined) return null;
  return { total: m.value, profit: m.profit, returnPct: null, pricePct: m.price_pct ?? null, asOf: m.as_of ?? null };
}

/** The first autocall scenario as "if called"; null when none is left (it runs to maturity) or it's unknown. */
export function calledNext(s: CallScenario | null | undefined): IfCalled | null {
  if (!s || !s.pay_date || s.total === null || s.total === undefined) return null;
  return {
    obsDate: s.obs_date,
    payDate: s.pay_date,
    total: s.total,
    profit: s.profit,
    returnPct: s.return_pct ?? null,
    annualisedPct: s.annualised_pct ?? null,
    triggerPct: s.trigger_pct ?? null,
  };
}

/** "If called 22 Mar 2027" (the day it would pay). */
export function calledLabel(c: Pick<IfCalled, "payDate">, style: "short" | "long" = "long"): string {
  return `If called ${formatDate(c.payDate, style)}`;
}

/** "15.32% · 28.12% a year" / "15.32%"; "—" without a return. */
export function returnText(returnPct: string | null | undefined, annualisedPct?: string | null): string {
  const r = returnPct ? pct(returnPct, 2) : "—";
  return annualisedPct ? `${r} · ${pct(annualisedPct, 2)} a year` : r;
}

// ── payout branches ────────────────────────────────────────────────────────

export interface PayoutBranch {
  min_worst_pct: string;
  intercept_pct: string;
  slope: string;
  settlement: string;
}

/** A branch's formula in words: "100%", "WP − 24.5%", "1.667 × WP", "0%". WP is the worst share's level. */
export function branchFormula(b: Pick<PayoutBranch, "intercept_pct" | "slope">): string {
  const slope = Number(b.slope);
  const intercept = Number(b.intercept_pct);
  if (!Number.isFinite(slope) || !Number.isFinite(intercept)) return "—";
  if (slope === 0) return pct(b.intercept_pct);
  const wp = slope === 1 ? "WP" : `${trimDecimal(String(Math.round(slope * 1000) / 1000))} × WP`;
  if (intercept === 0) return wp;
  const abs = trimDecimal(String(Math.abs(intercept)));
  return `${wp} ${intercept < 0 ? "−" : "+"} ${abs}%`;
}

/** The branches as rows of "worst at or above X%" → what it pays, highest first; the last reads "below Y%". */
export function payoutRows(branches: readonly PayoutBranch[]): { when: string; pays: string; physical: boolean }[] {
  const sorted = [...branches].sort((a, b) => Number(b.min_worst_pct) - Number(a.min_worst_pct));
  return sorted.map((b, i) => {
    const min = Number(b.min_worst_pct);
    const upper = sorted[i - 1]?.min_worst_pct ?? null;
    const when = min === 0 ? (upper ? `Worst below ${pct(upper)}` : "Any level") : upper ? `Worst ${pct(b.min_worst_pct)} to ${pct(upper)}` : `Worst ≥ ${pct(b.min_worst_pct)}`;
    return { when, pays: branchFormula(b), physical: b.settlement === "physical" };
  });
}

// ── the review form ────────────────────────────────────────────────────────

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

export interface DraftBranch extends PayoutBranch {
  description?: string;
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

export interface NoteDraft {
  name: string;
  terms: DraftTerms;
  termsheet_path?: string | null;
  termsheet_filename?: string | null;
  extracted_terms?: unknown;
}

export interface InvestmentForm {
  invested_amount: string;
  purchase_price_pct: string;
  nominal: string;
  trade_date: string;
  funding_account_code: string;
}

const DEC = /^-?\d+(\.\d+)?$/;
const ISO = /^\d{4}-\d{2}-\d{2}$/;

/** A typed number as a decimal string ("1,000.50" → "1000.50", "98%" → "98"); null when not one. */
export function cleanDecimal(v: string | null | undefined): string | null {
  const s = (v ?? "").replace(/[,%\s]/g, "").replace(/−/g, "-");
  return DEC.test(s) ? s : null;
}

/** Problems with the reviewed terms and the investment, as sentences; empty when it can be saved. */
export function draftProblems(d: NoteDraft, inv: InvestmentForm): string[] {
  const p: string[] = [];
  const t = d.terms;
  if (!d.name.trim()) p.push("Give the note a name.");
  if (!/^[A-Z]{3}$/.test(t.currency.trim().toUpperCase())) p.push("The currency is a 3-letter code, e.g. USD.");
  if (!cleanDecimal(t.denomination) || Number(cleanDecimal(t.denomination)) <= 0) p.push("Enter the denomination.");
  if (!cleanDecimal(t.issue_price_pct) || Number(cleanDecimal(t.issue_price_pct)) <= 0) p.push("Enter the issue price in %.");
  for (const [k, label] of [
    ["strike_date", "strike date"],
    ["final_valuation_date", "final valuation date"],
    ["maturity_date", "maturity date"],
  ] as const) {
    if (!ISO.test(t[k])) p.push(`Enter the ${label} (YYYY-MM-DD).`);
  }
  if (ISO.test(t.strike_date) && ISO.test(t.final_valuation_date) && ISO.test(t.maturity_date)) {
    if (!(t.strike_date <= t.final_valuation_date && t.final_valuation_date <= t.maturity_date)) {
      p.push("The strike, final valuation and maturity dates must be in that order.");
    }
  }
  if (t.underlyings.length === 0) p.push("Add at least one underlying share.");
  t.underlyings.forEach((u, i) => {
    const who = u.name.trim() || `Share ${i + 1}`;
    if (!/^[A-Za-z0-9^][A-Za-z0-9.^=-]{0,19}$/.test(u.symbol.trim())) p.push(`${who}: enter its price symbol (e.g. AMZN).`);
    if (!cleanDecimal(u.initial_level) || Number(cleanDecimal(u.initial_level)) <= 0) p.push(`${who}: enter its initial level.`);
  });
  if (!t.payout.some((b) => Number(cleanDecimal(b.min_worst_pct)) === 0)) {
    p.push("The payout needs a branch from 0%: what is paid however far the worst share falls.");
  }
  t.payout.forEach((b, i) => {
    if ([b.min_worst_pct, b.intercept_pct, b.slope].some((x) => cleanDecimal(x) === null)) p.push(`Payout row ${i + 1} has a value that isn't a number.`);
  });
  t.observations.forEach((o) => {
    if (!ISO.test(o.obs_date) || !ISO.test(o.pay_date)) p.push("Every observation needs an observation and a payment date.");
  });
  const invested = cleanDecimal(inv.invested_amount);
  if (!invested || Number(invested) <= 0 || !/^\d+(\.\d{1,2})?$/.test(invested)) p.push("Enter how much you invested (up to 2 decimals).");
  if (inv.purchase_price_pct && !cleanDecimal(inv.purchase_price_pct)) p.push("The price you paid is a percent, e.g. 74.5.");
  if (inv.nominal && !cleanDecimal(inv.nominal)) p.push("The nominal is an amount, e.g. 50000.");
  if (inv.trade_date && !ISO.test(inv.trade_date)) p.push("The trade date is YYYY-MM-DD.");
  return [...new Set(p)];
}

const nul = (v: string | null | undefined) => (v === null || v === undefined || v.trim() === "" ? null : cleanDecimal(v));

/** The reviewed draft and investment as create_structured_note's p_draft. */
export function createNoteDraft(d: NoteDraft, inv: InvestmentForm, institution: string | null): Record<string, unknown> {
  const t = d.terms;
  return {
    name: d.name.trim(),
    institution,
    termsheet_path: d.termsheet_path ?? null,
    termsheet_filename: d.termsheet_filename ?? null,
    extracted_terms: d.extracted_terms ?? null,
    terms: {
      product_name: t.product_name.trim() || d.name.trim(),
      isin: t.isin?.trim() || null,
      issuer: t.issuer?.trim() || null,
      guarantor: t.guarantor?.trim() || null,
      currency: t.currency.trim().toUpperCase(),
      denomination: cleanDecimal(t.denomination),
      issue_price_pct: cleanDecimal(t.issue_price_pct),
      strike_date: t.strike_date,
      issue_date: t.issue_date || null,
      final_valuation_date: t.final_valuation_date,
      maturity_date: t.maturity_date,
      underlyings: t.underlyings.map((u) => ({
        name: u.name.trim(),
        symbol: u.symbol.trim().toUpperCase(),
        bloomberg_code: u.bloomberg_code,
        isin: u.isin,
        exchange: u.exchange,
        initial_level: cleanDecimal(u.initial_level),
      })),
      observations: t.observations.map((o) => ({
        obs_date: o.obs_date,
        pay_date: o.pay_date,
        coupon_rate_pct: nul(o.coupon_rate_pct),
        coupon_barrier_pct: nul(o.coupon_barrier_pct),
        coupon_memory: o.coupon_memory,
        autocall_trigger_pct: nul(o.autocall_trigger_pct),
        autocall_amount_pct: nul(o.autocall_amount_pct),
      })),
      payout: t.payout.map((b) => ({
        min_worst_pct: cleanDecimal(b.min_worst_pct),
        intercept_pct: cleanDecimal(b.intercept_pct),
        slope: cleanDecimal(b.slope),
        settlement: b.settlement === "physical" ? "physical" : "cash",
      })),
    },
    investment: {
      invested_amount: cleanDecimal(inv.invested_amount),
      purchase_price_pct: nul(inv.purchase_price_pct),
      nominal: nul(inv.nominal),
      trade_date: inv.trade_date || null,
      funding_account_code: inv.funding_account_code || null,
    },
  };
}

/** The schedule in one line: "48 monthly coupons of 0.667% (98% barrier, memory) · autocall 105% from 22 Apr 2027". */
export function scheduleSummary(obs: readonly DraftObservation[]): string {
  const coupons = obs.filter((o) => o.coupon_rate_pct !== null);
  const calls = obs.filter((o) => o.autocall_trigger_pct !== null);
  const parts: string[] = [];
  if (coupons.length > 0) {
    const rates = [...new Set(coupons.map((o) => trimDecimal(o.coupon_rate_pct)))];
    const barriers = [...new Set(coupons.map((o) => trimDecimal(o.coupon_barrier_pct)))];
    const memory = coupons.some((o) => o.coupon_memory);
    parts.push(
      `${coupons.length} coupon${coupons.length === 1 ? "" : "s"} of ${rates.length === 1 ? pct(rates[0]) : "varying rates"}` +
        ` (${barriers.length === 1 ? `${pct(barriers[0])} barrier` : "varying barriers"}${memory ? ", memory" : ""})`,
    );
  }
  if (calls.length > 0) {
    const triggers = [...new Set(calls.map((o) => trimDecimal(o.autocall_trigger_pct)))];
    parts.push(
      `${calls.length} autocall date${calls.length === 1 ? "" : "s"} from ${formatDate(calls[0]?.obs_date)}` +
        ` at ${triggers.length === 1 ? pct(triggers[0]) : `${pct(triggers[0])} stepping to ${pct(triggers[triggers.length - 1])}`}`,
    );
  }
  return parts.join(" · ") || "No coupons or autocalls";
}

// ── chart and scenario tables ──────────────────────────────────────────────

/** Each share's closes (% of initial) merged by date for the chart; numbers for drawing only. */
export function seriesRows(series: Record<string, [string, string][]>): { date: string; [symbol: string]: number | string }[] {
  const byDate = new Map<string, { date: string; [symbol: string]: number | string }>();
  for (const [symbol, points] of Object.entries(series)) {
    for (const [date, value] of points) {
      const row = byDate.get(date) ?? { date };
      row[symbol] = Number(value);
      byDate.set(date, row);
    }
  }
  return [...byDate.values()].sort((a, b) => a.date.localeCompare(b.date));
}

/** The payoff curve's rows worth a line in the table: every 10%, and the points either side of each branch level. */
export function maturityTableRows<T extends { worst_pct: string; payout_pct: string }>(curve: readonly T[], branches: readonly PayoutBranch[]): T[] {
  const levels = new Set(branches.map((b) => Number(b.min_worst_pct)).filter((x) => x > 0));
  return curve.filter((p, i) => {
    const wp = Number(p.worst_pct);
    if (wp % 10 === 0) return true;
    const next = curve[i + 1];
    return [...levels].some((l) => wp === l || (next && wp < l && Number(next.worst_pct) > l));
  });
}
