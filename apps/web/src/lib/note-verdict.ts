// A structured note in one line, and its shares as bars (docs: the notes redesign). The verdict
// (private.note_verdict via broker_portfolio, structured_notes_summary and structured_note_detail)
// is the server's: kind, the stock holding the note back, its gap and the date. These helpers only
// word it and place marks on a bar; the bar positions are presentational arithmetic, never money
// (CLAUDE.md §2.2). Pure, unit-tested.
import { daysBetween, formatDate, todayDubai, type ISODate } from "./dates";
import { trimDecimal } from "./holdings";
import { formatMoney } from "./money";
import { pct } from "./notes";

/**
 * on_track | needs | coupon_at_risk | to_maturity (equity), cln_paying | cln_accruing
 * (credit-linked), awaiting_prices | ended; a kind this build doesn't know shows nothing.
 */
export interface NoteVerdict {
  kind: string;
  symbol?: string | null;
  gap_pct?: string | null;
  /** The check or call date; cln_paying: the next coupon; cln_accruing: the next call or maturity. */
  date?: string | null;
  call_gap_pct?: string | null;
  call_date?: string | null;
  /** Credit-linked: the coupon rate a year. */
  rate_pct?: string | null;
  /** cln_paying: the next coupon; cln_accruing: the interest accrued so far. */
  amount?: string | null;
  maturity_date?: string | null;
}

/** A credit-linked note's verdict: no shares to draw, and its amounts need the note's currency. */
export function isCreditVerdict(v: NoteVerdict | null | undefined): boolean {
  return v?.kind === "cln_paying" || v?.kind === "cln_accruing";
}

export type VerdictTone = "positive" | "neutral" | "warn" | "danger";

export interface VerdictLine {
  text: string;
  tone: VerdictTone;
}

/** Above this gap a "needs" verdict reads as a warning. */
export const NEEDS_WARN_PCT = 10;

const num = (v: string | null | undefined): number | null => {
  if (v === null || v === undefined || v.trim() === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

/** "9.3%" from "9.33": a gap is worded to one decimal, without its sign. */
export function gapText(v: string | null | undefined): string {
  const n = num(v);
  return n === null ? "—" : pct(String(Math.abs(n)), 1);
}

/** "15 Mar" within the next ~10 months, "15 Mar 2028" further out (so the year is never ambiguous). */
export function verdictDate(d: string | null | undefined, today: ISODate = todayDubai()): string {
  if (!d) return "—";
  return Math.abs(daysBetween(today, d)) <= 300 ? formatDate(d, "short") : formatDate(d);
}

/** "Jun 2028". */
export function monthYear(d: string | null | undefined): string {
  const [, m, y] = formatDate(d).split(" ");
  return m && y ? `${m} ${y}` : "—";
}

/**
 * The note's headline: what has to happen, in plain words, and how it reads (tone). Null for an
 * unknown kind. `currency` words a credit-linked note's amounts (the note page words them at length:
 * lib/credit-notes creditVerdict).
 */
export function verdictLine(v: NoteVerdict | null | undefined, today: ISODate = todayDubai(), currency?: string): VerdictLine | null {
  if (!v) return null;
  const money = (x: string) => formatMoney(x, { currency });
  const sym = v.symbol ?? "the weakest stock";
  const gap = num(v.gap_pct);
  switch (v.kind) {
    case "on_track":
      return { text: `On track to be called on ${verdictDate(v.date, today)}`, tone: "positive" };
    case "needs":
      if (gap !== null && gap <= 0) return { text: `On track to be called on ${verdictDate(v.date, today)}`, tone: "positive" };
      return { text: `Called on ${verdictDate(v.date, today)} if ${sym} rises ${gapText(v.gap_pct)}`, tone: gap !== null && gap > NEEDS_WARN_PCT ? "warn" : "neutral" };
    case "coupon_at_risk":
      return { text: `Coupon at risk: ${sym} is ${gapText(v.gap_pct)} below the barrier (check ${verdictDate(v.date, today)})`, tone: "warn" };
    case "to_maturity":
      return gap === null || gap <= 0
        ? { text: `Runs to ${monthYear(v.date)} · capital safe while ${sym} stays above its break-even`, tone: "neutral" }
        : { text: `Runs to ${monthYear(v.date)} · ${sym} is ${gapText(v.gap_pct)} below break-even`, tone: "danger" };
    case "cln_paying":
      return { text: `Paying ${pct(v.rate_pct)} a year${v.amount && v.date ? ` · next coupon ${money(v.amount)} on ${verdictDate(v.date, today)}` : ""}`, tone: "positive" };
    case "cln_accruing":
      return { text: `${pct(v.rate_pct)} a year, building up${v.amount ? ` · ${money(v.amount)} accrued` : ""}`, tone: "neutral" };
    case "awaiting_prices":
      return { text: "Waiting for today's prices", tone: "neutral" };
    case "ended":
      return { text: "Ended", tone: "neutral" };
    default:
      return null;
  }
}

/** The text colour class for a verdict tone (design tokens only). */
export const VERDICT_TEXT: Record<VerdictTone, string> = {
  positive: "text-positive",
  neutral: "text-ink",
  warn: "text-warn",
  danger: "text-danger",
};

// ── the next check ─────────────────────────────────────────────────────────

export interface NextCheck {
  obs_date: string;
  days: number;
  is_final: boolean;
  coupon?: { amount?: string | null; barrier_pct?: string | null } | null;
  autocall?: { trigger_pct?: string | null } | null;
}

/**
 * "Next check 15 Mar 2027 · in 139 days · called if every stock is at or above 100% of its start".
 * Null when no check is left; without `withCondition`, only when and how soon.
 */
export function nextCheckLine(next: NextCheck | null | undefined, withCondition = true): string | null {
  if (!next) return null;
  const when = `${next.is_final ? "Final check" : "Next check"} ${formatDate(next.obs_date)} · ${next.days <= 0 ? "today" : `in ${next.days} day${next.days === 1 ? "" : "s"}`}`;
  if (!withCondition) return when;
  if (next.autocall?.trigger_pct) return `${when} · called if every stock is at or above ${pct(next.autocall.trigger_pct)} of its start`;
  if (next.coupon?.barrier_pct) return `${when} · coupon paid if every stock is at or above ${pct(next.coupon.barrier_pct)} of its start`;
  return when;
}

/** For a coupon at risk: "Coupon of $146.74 is paid only if every stock is above 98% of its start". */
export function couponLine(next: NextCheck | null | undefined, money: (v: string) => string): string | null {
  const c = next?.coupon;
  if (!c?.amount || !c.barrier_pct) return null;
  return `Coupon of ${money(c.amount)} is paid only if every stock is above ${pct(c.barrier_pct)} of its start`;
}

// ── per-stock bars ─────────────────────────────────────────────────────────

/** A share of a live note as the evaluator sees it today (decimal strings). */
export interface NoteShare {
  symbol: string;
  name?: string | null;
  initial: string;
  close: string | null;
  perf_pct?: string | null;
  is_worst?: boolean;
  to_autocall_pct?: string | null;
  to_coupon_pct?: string | null;
  to_break_even_pct?: string | null;
  autocall_level?: string | null;
  coupon_level?: string | null;
  break_even_level?: string | null;
}

export type BarTone = "positive" | "warn" | "danger";

export interface ShareBar {
  symbol: string;
  name: string | null;
  /** "316.8" and "346.36", as the server sent them (trimmed). */
  close: string;
  start: string;
  /** Positions on the bar, 0–100 (%); null when the level doesn't apply. */
  callAt: number | null;
  barrierAt: number | null;
  barrierKind: "coupon" | "break_even" | null;
  dotAt: number;
  startAt: number;
  dotTone: BarTone;
  /** "at call level", "needs +9.3%", "above break-even". */
  status: string;
  statusMet: boolean;
  worst: boolean;
}

const PAD = 0.06;

/**
 * One bar per priced share, the stock holding the note back first. The bar runs from the lowest
 * relevant level (the barrier, the close or the start) to the highest (the call level, the close or
 * the start), padded a little; marks are placed on it. The dot's tone and the status come from the
 * server's distances (to_autocall_pct, to_coupon_pct / to_break_even_pct), not from comparing levels.
 */
export function shareBars(shares: readonly NoteShare[] | null | undefined): ShareBar[] {
  if (!Array.isArray(shares)) return [];
  const bars: (ShareBar & { sortKey: number })[] = [];
  for (const u of shares) {
    const close = num(u?.close);
    const start = num(u?.initial);
    if (!u || close === null || start === null) continue;
    const call = num(u.autocall_level);
    const coupon = num(u.coupon_level);
    const breakEven = num(u.break_even_level);
    const barrier = coupon ?? breakEven;
    const barrierKind = coupon !== null ? "coupon" : breakEven !== null ? "break_even" : null;
    const lo0 = Math.min(close, start, ...(barrier !== null ? [barrier] : []));
    const hi0 = Math.max(close, start, ...(call !== null ? [call] : []));
    const span0 = hi0 - lo0 || Math.abs(hi0) || 1;
    const lo = lo0 - span0 * PAD;
    const hi = hi0 + span0 * PAD;
    const at = (x: number) => Math.round(((x - lo) / (hi - lo)) * 1000) / 10;

    const toCall = num(u.to_autocall_pct);
    const toBarrier = num(barrierKind === "coupon" ? u.to_coupon_pct : u.to_break_even_pct);
    const toBreakEven = num(u.to_break_even_pct);
    const dotTone: BarTone =
      toCall !== null && toCall <= 0 ? "positive" : toBarrier !== null && toBarrier > 0 ? "danger" : toCall === null && toBarrier !== null ? "positive" : "warn";

    let status: string;
    let statusMet: boolean;
    if (toCall !== null) {
      statusMet = toCall <= 0;
      status = statusMet ? "at call level" : `needs +${gapText(u.to_autocall_pct)}`;
    } else if (toBreakEven !== null) {
      statusMet = toBreakEven <= 0;
      status = statusMet ? "above break-even" : `needs +${gapText(u.to_break_even_pct)}`;
    } else {
      statusMet = false;
      status = "";
    }

    bars.push({
      symbol: u.symbol,
      name: u.name ?? null,
      close: trimDecimal(u.close),
      start: trimDecimal(u.initial),
      callAt: call === null ? null : at(call),
      barrierAt: barrier === null ? null : at(barrier),
      barrierKind,
      dotAt: at(close),
      startAt: at(start),
      dotTone,
      status,
      statusMet,
      worst: !!u.is_worst,
      sortKey: (u.is_worst ? -1e9 : 0) + (num(u.perf_pct ?? null) ?? Infinity),
    });
  }
  return bars.sort((a, b) => a.sortKey - b.sortKey).map(({ sortKey: _k, ...bar }) => bar);
}
