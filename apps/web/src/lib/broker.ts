// A broker account's portfolio (broker_portfolio, 20261027165732_swissquote_sync.sql): the payload's
// shape, a tolerant reader for it, and the wording of what it says. Every figure (totals, profit,
// sell-today and if-called scenarios, returns) is the server's (CLAUDE.md §2.2); money stays a
// decimal string and is only converted to a number to draw the chart. Pure, unit-tested.
import { daysBetween, formatDate, formatMonth, formatRelative } from "./dates";
import { toAmount, type MoneyInput } from "./money";
import { trimDecimal } from "./holdings";
import { distanceMet, distanceText, isEnded, pct, type CallScenario, type SellToday } from "./notes";

export interface BrokerSync {
  last_synced_at: string | null;
  last_attempt_at: string | null;
  status: string | null;
  error: string | null;
}

export interface BrokerNoteNext {
  kind: string;
  obs_date: string;
  pay_date: string;
  days: number;
  is_final: boolean;
  coupon?: { would_pay: boolean } | null;
  autocall?: { would_call: boolean } | null;
}

export interface BrokerPositionNote {
  status: string;
  next: BrokerNoteNext | null;
  if_called_next: CallScenario | null;
  if_ended_today: { total: string; profit: string } | null;
  worst_now: { pct: string; symbol: string; priced: boolean } | null;
  awaiting_prices: boolean;
  /** Each share against its initial level and the next autocall (absent on an older payload). */
  underlyings?: BrokerNoteShare[] | null;
}

/** A note's share as the evaluator sees it today (decimal strings). */
export interface BrokerNoteShare {
  symbol: string;
  name?: string | null;
  initial: string;
  close: string | null;
  close_date?: string | null;
  perf_pct: string | null;
  is_worst?: boolean;
  to_autocall_pct: string | null;
  autocall_level?: string | null;
}

/** One share's line on a position: "now 316.8 vs 346.36 initial", its % of initial, and the distance to the next call. */
export interface ShareLine {
  symbol: string;
  levels: string;
  perf: string;
  toCall: string | null;
  callMet: boolean;
  worst: boolean;
}

/** The shares of a live note, worst first; empty when the note has ended or no share has a close. */
export function shareLines(note: BrokerPositionNote | null | undefined): ShareLine[] {
  if (!note || isEnded(note.status) || !Array.isArray(note.underlyings)) return [];
  return note.underlyings
    .filter((u) => u && u.close !== null && u.close !== undefined)
    .map((u) => ({
      symbol: u.symbol,
      levels: `${trimDecimal(u.close!)} vs ${trimDecimal(u.initial)}`,
      perf: pct(u.perf_pct, 1),
      toCall: u.to_autocall_pct === null || u.to_autocall_pct === undefined ? null : distanceText(u.to_autocall_pct),
      callMet: distanceMet(u.to_autocall_pct),
      worst: !!u.is_worst,
      sortKey: Number(u.perf_pct ?? Infinity),
    }))
    .sort((a, b) => a.sortKey - b.sortKey)
    .map(({ sortKey: _k, ...line }) => line);
}

/** structured_note | broker | security; another kind reads as a security. */
export type PositionKind = "structured_note" | "broker" | "security";

export interface BrokerPosition {
  holding_code: string;
  kind: string;
  name: string;
  isin: string | null;
  security_name: string | null;
  symbol: string | null;
  product_type: string | null;
  quantity: string | null;
  price: string | null;
  price_in_pct: boolean;
  currency: string;
  value: string | null;
  value_aed: string | null;
  as_of: string | null;
  cost: string | null;
  profit: string | null;
  invested: string | null;
  income: string | null;
  sell_now: { total: string; profit: string; return_pct: string | null } | null;
  note: BrokerPositionNote | null;
}

export interface ClosedPosition {
  holding_code: string;
  kind: string;
  name: string;
  isin: string | null;
  invested: string | null;
  returned: string | null;
  income: string | null;
  profit: string | null;
  return_pct: string | null;
  annualised_pct: string | null;
  opened_on: string | null;
  closed_on: string | null;
  note_status: string | null;
}

export interface PortfolioDay {
  as_of: string;
  total: string | null;
  cash: string | null;
  positions: string | null;
  net_deposits: string | null;
  /** Rebuilt from the broker's performance index, not a daily mark. */
  estimated: boolean;
}

export interface BrokerPortfolio {
  account_code: string;
  provider: string;
  portfolio_ref: string | null;
  currency: string;
  sync: BrokerSync;
  as_of: string | null;
  cash: string | null;
  positions_value: string | null;
  total: string | null;
  total_aed: string | null;
  net_deposits: string | null;
  profit: string | null;
  income: string | null;
  fees: string | null;
  positions: BrokerPosition[];
  closed: ClosedPosition[];
  series: PortfolioDay[];
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const list = <T>(v: unknown): T[] => (Array.isArray(v) ? (v.filter(isObject) as unknown as T[]) : []);

/**
 * broker_portfolio's jsonb as a portfolio; null when the account has no sync (the RPC returns null)
 * or the payload isn't one. Missing lists read as empty and a missing sync as never synced, so an
 * older or partial payload still renders.
 */
export function parseBrokerPortfolio(raw: unknown): BrokerPortfolio | null {
  if (!isObject(raw) || typeof raw.account_code !== "string") return null;
  const sync = isObject(raw.sync) ? raw.sync : {};
  const str = (v: unknown) => (typeof v === "string" ? v : null);
  return {
    ...(raw as unknown as BrokerPortfolio),
    currency: str(raw.currency) ?? "USD",
    provider: str(raw.provider) ?? "broker",
    sync: { last_synced_at: str(sync.last_synced_at), last_attempt_at: str(sync.last_attempt_at), status: str(sync.status), error: str(sync.error) },
    positions: list<BrokerPosition>(raw.positions).map((p) => ({ ...p, note: isObject(p.note) ? p.note : null, sell_now: isObject(p.sell_now) ? p.sell_now : null })),
    closed: list<ClosedPosition>(raw.closed),
    series: list<PortfolioDay>(raw.series)
      .filter((d) => typeof d.as_of === "string")
      .map((d) => ({ ...d, estimated: d.estimated === true }))
      .sort((a, b) => a.as_of.localeCompare(b.as_of)),
  };
}

export function positionKind(kind: string | null | undefined): PositionKind {
  return kind === "structured_note" || kind === "broker" ? kind : "security";
}

/** The provider's name for people: "swissquote" → "Swissquote". */
export function providerLabel(provider: string | null | undefined): string {
  const p = (provider ?? "").trim();
  return p ? p.charAt(0).toUpperCase() + p.slice(1) : "Broker";
}

/** The sync line under the portfolio: when it last synced, or why the last attempt failed. */
export function syncStatus(sync: BrokerSync, now: Date = new Date()): { text: string; tone: "muted" | "danger" } {
  if (sync.status === "error") {
    const when = sync.last_attempt_at ? ` ${formatRelative(sync.last_attempt_at, now)}` : "";
    const last = sync.last_synced_at ? `; last good sync ${formatRelative(sync.last_synced_at, now)}` : "";
    return { text: `Sync failed${when}: ${sync.error?.trim() || "no reason given"}${last}`, tone: "danger" };
  }
  if (sync.last_synced_at) return { text: `Synced ${formatRelative(sync.last_synced_at, now)}`, tone: "muted" };
  return { text: "Not synced yet", tone: "muted" };
}

/** The position's sub-line: ISIN and ticker ("XS123 · AMZN"), whichever it has. */
export function positionRef(p: Pick<BrokerPosition, "isin" | "symbol">): string {
  return [p.isin, p.symbol && p.symbol !== p.isin ? p.symbol : null].filter(Boolean).join(" · ");
}

/** A quantity for display: "25,000", "32", "1.5". */
export function formatQuantity(q: string | null | undefined): string {
  const t = trimDecimal(q);
  if (!t) return "—";
  const [whole = "", frac] = t.replace(/^-/, "").split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${t.startsWith("-") ? "−" : ""}${grouped}${frac ? `.${frac}` : ""}`;
}

/** A position's price: "93.42%" of nominal for a note or bond, "253.64" a share otherwise. */
export function formatPositionPrice(p: Pick<BrokerPosition, "price" | "price_in_pct">): string {
  if (!p.price) return "—";
  if (p.price_in_pct) return pct(p.price, 2);
  const n = toAmount(p.price);
  return n === null ? "—" : new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4 }).format(n);
}

/** What the position fetches sold today (with income received) and its profit on what was put in; null without a price. */
export function sellFromPosition(p: Pick<BrokerPosition, "sell_now" | "price" | "price_in_pct" | "as_of">): SellToday | null {
  if (!p.sell_now) return null;
  return {
    total: p.sell_now.total,
    profit: p.sell_now.profit,
    returnPct: p.sell_now.return_pct ?? null,
    pricePct: p.price_in_pct ? p.price : null,
    asOf: p.as_of,
  };
}

// ── chart ──────────────────────────────────────────────────────────────────

export interface PortfolioPoint {
  date: string;
  /** For drawing only. The total split into a solid (daily mark) and a dashed (estimated) line. */
  marked: number | null;
  estimated: number | null;
  deposits: number | null;
  isEstimated: boolean;
  /** The server's figures for the tooltip. */
  day: PortfolioDay;
}

/**
 * The series as chart points. A segment touching an estimated day is drawn dashed: an estimated
 * point and its neighbours carry `estimated`, so the dashed and solid lines meet at the first mark.
 */
export function portfolioPoints(series: readonly PortfolioDay[]): PortfolioPoint[] {
  return series.map((d, i) => {
    const total = toAmount(d.total as MoneyInput);
    const nearEstimate = d.estimated || !!series[i - 1]?.estimated || !!series[i + 1]?.estimated;
    return {
      date: d.as_of,
      marked: d.estimated ? null : total,
      estimated: nearEstimate ? total : null,
      deposits: toAmount(d.net_deposits as MoneyInput),
      isEstimated: d.estimated,
      day: d,
    };
  });
}

/** The chart's date ticks: "9 Dec" within a year, "Dec ’24" when the series spans more than one, so the year is never ambiguous. */
export function dateTickFormatter(points: readonly { date: string }[]): (d: string) => string {
  const first = points[0]?.date;
  const last = points[points.length - 1]?.date;
  const long = !!first && !!last && daysBetween(first, last) > 300;
  return long ? (d) => `${formatMonth(d, "short")} ’${d.slice(2, 4)}` : (d) => formatDate(d, "short");
}

/** The note under the chart when some days are estimated; null when every day is a daily mark. */
export function estimateNote(series: readonly PortfolioDay[]): string | null {
  if (!series.some((d) => d.estimated)) return null;
  const firstMark = series.find((d) => !d.estimated);
  if (!firstMark) return "Every day is estimated from the broker's performance index.";
  return `Dashed: estimated from the broker's performance index before ${formatDate(firstMark.as_of)}; daily marks since.`;
}

/** "3 Feb 2026 – 9 Sep 2026" for a closed position. */
export function heldSpan(c: Pick<ClosedPosition, "opened_on" | "closed_on">): string {
  if (!c.opened_on && !c.closed_on) return "—";
  return `${c.opened_on ? formatDate(c.opened_on) : "?"} – ${c.closed_on ? formatDate(c.closed_on) : "?"}`;
}
