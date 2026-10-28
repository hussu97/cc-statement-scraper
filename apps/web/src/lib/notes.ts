// Structured notes (Wealth → Investments): wording for what the server sends. Every figure
// (coupons, redemptions, distances, payouts, scenarios) is computed by private.note_evaluate
// (CLAUDE.md §2.2); these helpers only word it. Notes are created by the broker sync from their
// term sheets, never typed in here. Pure, unit-tested.
import { formatDate } from "./dates";
import { trimDecimal } from "./holdings";

// ── statuses and outcomes ──────────────────────────────────────────────────

/** called (the issuer's call) and credit_event are a credit-linked note's (20261028110553). */
export type NoteStatus = "live" | "awaiting_strike" | "autocalled" | "called" | "matured" | "credit_event" | "cancelled";

type StatusTone = "accent" | "positive" | "neutral" | "warn" | "danger";

export const NOTE_STATUS: Record<NoteStatus, { label: string; tone: StatusTone }> = {
  live: { label: "Live", tone: "accent" },
  awaiting_strike: { label: "Not struck yet", tone: "neutral" },
  autocalled: { label: "Called early", tone: "positive" },
  called: { label: "Called by issuer", tone: "positive" },
  matured: { label: "Matured", tone: "neutral" },
  credit_event: { label: "Credit event", tone: "danger" },
  cancelled: { label: "Cancelled", tone: "warn" },
};

export function noteStatus(s: string | null | undefined): { label: string; tone: StatusTone } {
  return NOTE_STATUS[(s ?? "live") as NoteStatus] ?? NOTE_STATUS.live;
}

const ENDED = new Set(["autocalled", "called", "matured", "credit_event", "cancelled"]);

export function isEnded(s: string | null | undefined): boolean {
  return ENDED.has(s ?? "");
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

/** The branches as rows of "lowest stock at or above X%" → what it pays, highest first; the last reads "below Y%". */
export function payoutRows(branches: readonly PayoutBranch[]): { when: string; pays: string; physical: boolean }[] {
  const sorted = [...branches].sort((a, b) => Number(b.min_worst_pct) - Number(a.min_worst_pct));
  return sorted.map((b, i) => {
    const min = Number(b.min_worst_pct);
    const upper = sorted[i - 1]?.min_worst_pct ?? null;
    const when = min === 0 ? (upper ? `Lowest stock below ${pct(upper)}` : "Any level") : upper ? `Lowest stock ${pct(b.min_worst_pct)} to ${pct(upper)}` : `Lowest stock ≥ ${pct(b.min_worst_pct)}`;
    return { when, pays: branchFormula(b), physical: b.settlement === "physical" };
  });
}

// ── typed amounts ──────────────────────────────────────────────────────────

const DEC = /^-?\d+(\.\d+)?$/;

/** A typed number as a decimal string ("1,000.50" → "1000.50", "98%" → "98"); null when not one. */
export function cleanDecimal(v: string | null | undefined): string | null {
  const s = (v ?? "").replace(/[,%\s]/g, "").replace(/−/g, "-");
  return DEC.test(s) ? s : null;
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
