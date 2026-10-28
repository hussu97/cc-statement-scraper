// A broker account's portfolio (broker_portfolio, 20261027165732_swissquote_sync.sql): the payload's
// shape, a tolerant reader for it, and the wording of what it says. Every figure (totals, profit,
// sell-today and if-called scenarios, returns) is the server's (CLAUDE.md §2.2); money stays a
// decimal string and is only converted to a number to draw the chart. Pure, unit-tested.
import { daysBetween, formatDate, formatMonth, formatRelative } from "./dates";
import { formatTotal, toAmount, type MoneyInput } from "./money";
import { isEnded, type CallScenario } from "./notes";
import type { NoteShare, NoteVerdict } from "./note-verdict";

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
  /** The note in one line (absent on an older payload): lib/note-verdict words it. */
  verdict?: NoteVerdict | null;
  /** Each share against its start, the call level and the barrier (absent on an older payload). */
  underlyings?: NoteShare[] | null;
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
  /** Zerodha: kite | coin; absent elsewhere and on an older payload. */
  segment?: string | null;
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
  /** The cost of the positions held that day (absent on an older payload). */
  invested?: string | null;
  /** Rebuilt from the broker's performance index, not a daily mark. */
  estimated: boolean;
}

/**
 * What the profit is measured against: `deposits` (net money paid in, Swissquote) or `cost` (what
 * the positions cost; Zerodha, which has no deposit history).
 */
export type Basis = "deposits" | "cost";

/** Zerodha's Kite or Coin in one line: invested, worth now, P&L. */
export interface SegmentTotal {
  segment: string;
  positions: string | null;
  invested: string | null;
  value: string | null;
  value_aed: string | null;
  profit: string | null;
  return_pct: string | null;
}

export interface BrokerPortfolio {
  account_code: string;
  provider: string;
  portfolio_ref: string | null;
  currency: string;
  basis: Basis;
  sync: BrokerSync;
  as_of: string | null;
  cash: string | null;
  positions_value: string | null;
  total: string | null;
  total_aed: string | null;
  net_deposits: string | null;
  /** The cost of the open positions. */
  invested: string | null;
  profit: string | null;
  income: string | null;
  fees: string | null;
  positions: BrokerPosition[];
  /** Kite and Coin (Zerodha); empty elsewhere. */
  segments: SegmentTotal[];
  closed: ClosedPosition[];
  /** Every closed position together (decimal strings; count too); null on an older payload. */
  closed_total: ClosedTotal | null;
  series: PortfolioDay[];
}

export interface ClosedTotal {
  count: string;
  invested: string | null;
  received: string | null;
  profit: string | null;
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
    basis: raw.basis === "cost" ? "cost" : "deposits",
    invested: str(raw.invested),
    segments: list<SegmentTotal>(raw.segments).filter((x) => typeof x.segment === "string"),
    sync: { last_synced_at: str(sync.last_synced_at), last_attempt_at: str(sync.last_attempt_at), status: str(sync.status), error: str(sync.error) },
    positions: list<BrokerPosition>(raw.positions).map((p) => ({ ...p, note: isObject(p.note) ? p.note : null, sell_now: isObject(p.sell_now) ? p.sell_now : null })),
    closed: list<ClosedPosition>(raw.closed),
    closed_total: isObject(raw.closed_total) ? (raw.closed_total as unknown as ClosedTotal) : null,
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

/** "Kite", "Coin"; another segment reads as "Other". */
export function segmentLabel(segment: string | null | undefined): string {
  return segment === "kite" ? "Kite" : segment === "coin" ? "Coin" : "Other";
}

/**
 * The segment lines under the three numbers: only when the account has more than one (a Zerodha
 * account from before Kite and Coin were split). Zerodha Kite and Zerodha Coin are each one
 * segment, and a single line would repeat the figures above it.
 */
export function segmentLines(p: Pick<BrokerPortfolio, "segments">): SegmentTotal[] {
  return p.segments.length > 1 ? p.segments : [];
}

/** What a segment holds, for its heading. */
export function segmentHolds(segment: string | null | undefined): string {
  return segment === "kite" ? "Stocks and ETFs" : segment === "coin" ? "Mutual funds" : "Other holdings";
}

/** Positions by segment (Kite, Coin, then any other), each group in the server's order; empty groups dropped. */
export function groupBySegment<T extends { segment?: string | null }>(positions: readonly T[]): { segment: string; items: T[] }[] {
  const order = ["kite", "coin"];
  const keyOf = (p: T) => (p.segment && order.includes(p.segment) ? p.segment : "other");
  return [...order, "other"].map((segment) => ({ segment, items: positions.filter((p) => keyOf(p) === segment) })).filter((g) => g.items.length > 0);
}

/** The words a portfolio uses for what it is measured against. */
export function basisWords(basis: Basis): { profit: string; line: string; past: string; ended: string } {
  return basis === "cost"
    ? { profit: "P&L", line: "Invested", past: "Sold", ended: "Holdings you sell are listed here with what they made." }
    : { profit: "Profit", line: "Put in", past: "Past notes", ended: "Notes that are called early or mature, and positions you sell, are listed here with what they made." };
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
export function portfolioPoints(series: readonly PortfolioDay[], basis: Basis = "deposits"): PortfolioPoint[] {
  // Against cost, the line is the holdings' worth against what they cost (cash aside).
  const cost = basis === "cost";
  return series.map((d, i) => {
    const total = toAmount((cost ? d.positions : d.total) as MoneyInput);
    const nearEstimate = d.estimated || !!series[i - 1]?.estimated || !!series[i + 1]?.estimated;
    return {
      date: d.as_of,
      marked: d.estimated ? null : total,
      estimated: nearEstimate ? total : null,
      deposits: toAmount((cost ? (d.invested ?? null) : d.net_deposits) as MoneyInput),
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

// ── the account page: notes, other holdings, past notes ────────────────────

/** A live structured note with its terms: it gets a card with its verdict and its shares. */
export function isLiveNote(p: Pick<BrokerPosition, "kind" | "note">): boolean {
  return positionKind(p.kind) === "structured_note" && !!p.note && !isEnded(p.note.status);
}

/** The positions as "Your notes" (live notes with terms) and "Other holdings" (shares, notes without terms, CLNs), in the server's order. */
export function splitPositions<T extends Pick<BrokerPosition, "kind" | "note">>(positions: readonly T[]): { notes: T[]; others: T[] } {
  return { notes: positions.filter(isLiveNote), others: positions.filter((p) => !isLiveNote(p)) };
}

/** What a holding made: sold today with its return when the server priced that, else its profit alone. */
export function holdingResult(p: Pick<BrokerPosition, "sell_now" | "profit">): { profit: string | null; returnPct: string | null } {
  if (p.sell_now) return { profit: p.sell_now.profit ?? null, returnPct: p.sell_now.return_pct ?? null };
  return { profit: p.profit ?? null, returnPct: null };
}

/** "6 called early · +USD 21,441 earned on USD 98,275"; null with nothing closed. */
export function pastHeadline(total: ClosedTotal | null, closed: readonly Pick<ClosedPosition, "note_status">[], currency: string): string | null {
  const count = total ? Number(total.count) : closed.length;
  if (!Number.isFinite(count) || count <= 0) return null;
  const allCalled = closed.length === count && closed.every((c) => c.note_status === "autocalled");
  const what = allCalled ? `${count} called early` : `${count} ended`;
  if (!total?.profit) return what;
  const lost = (toAmount(total.profit) ?? 0) < 0;
  const on = total.invested ? ` on ${formatTotal(total.invested, { currency })}` : "";
  return `${what} · ${formatTotal(total.profit, { currency, signed: true })} ${lost ? "lost" : "earned"}${on}`;
}

const yearOf = (d: string) => d.slice(0, 4);
// formatDate's month names ("Sep", never Intl's "Sept").
const monthOf = (d: string) => formatDate(d).split(" ")[1] ?? "—";

/** "held Feb–Sep 2026", "held Nov 2025–Mar 2026", "held Sep 2026"; "—" without dates. */
export function heldMonths(c: Pick<ClosedPosition, "opened_on" | "closed_on">): string {
  const a = c.opened_on;
  const b = c.closed_on;
  if (!a && !b) return "—";
  if (!a || !b) return `held ${a ? `from ${monthOf(a)} ${yearOf(a)}` : `to ${monthOf(b!)} ${yearOf(b!)}`}`;
  if (a.slice(0, 7) === b.slice(0, 7)) return `held ${monthOf(b)} ${yearOf(b)}`;
  if (yearOf(a) === yearOf(b)) return `held ${monthOf(a)}–${monthOf(b)} ${yearOf(b)}`;
  return `held ${monthOf(a)} ${yearOf(a)}–${monthOf(b)} ${yearOf(b)}`;
}
