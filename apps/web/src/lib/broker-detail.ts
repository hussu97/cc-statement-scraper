// A broker account in detail (Zerodha Kite and Coin, tasks/todo.md §14): the positions list's
// sort codec, the words for a position, a SIP and an allocation, and a tolerant reader for
// broker_position_detail (20261028062806_zerodha_position_detail.sql). Every figure is the
// server's (CLAUDE.md §2.2): sorting orders the server's numbers and money stays a decimal string
// until it is drawn. Pure, unit-tested.
import { formatDate } from "./dates";
import { formatTotal, toAmount, type MoneyInput } from "./money";
import { parseSips, type AllocationSlice, type BrokerPosition, type PortfolioPoint, type Sip } from "./broker";

// ── the positions list ─────────────────────────────────────────────────────

export const POSITION_SORTS = ["value", "return", "today", "weight", "name"] as const;
export type PositionSort = (typeof POSITION_SORTS)[number];
export const DEFAULT_POSITION_SORT: PositionSort = "value";

export const POSITION_SORT_LABEL: Record<PositionSort, string> = {
  value: "Value",
  return: "P&L %",
  today: "Today",
  weight: "Weight",
  name: "Name",
};

export function positionSort(raw: unknown): PositionSort {
  return typeof raw === "string" && (POSITION_SORTS as readonly string[]).includes(raw) ? (raw as PositionSort) : DEFAULT_POSITION_SORT;
}

/** The `?sort=` value for a choice: undefined for the default. */
export function positionSortParam(s: PositionSort): PositionSort | undefined {
  return s === DEFAULT_POSITION_SORT ? undefined : s;
}

type Sortable = Pick<BrokerPosition, "name" | "value" | "return_pct" | "day_change_pct" | "weight_pct">;

const SORT_FIELD: Record<Exclude<PositionSort, "name">, (p: Sortable) => MoneyInput> = {
  value: (p) => p.value,
  return: (p) => p.return_pct ?? null,
  today: (p) => p.day_change_pct ?? null,
  weight: (p) => p.weight_pct ?? null,
};

/** The positions by the chosen column: numbers largest first (unknowns last), names A–Z. A copy. */
export function sortPositions<T extends Sortable>(positions: readonly T[], sort: PositionSort): T[] {
  const byName = (a: T, b: T) => a.name.localeCompare(b.name);
  if (sort === "name") return [...positions].sort(byName);
  const field = SORT_FIELD[sort];
  return [...positions].sort((a, b) => {
    const x = toAmount(field(a));
    const y = toAmount(field(b));
    if (x === null || y === null) return x === y ? byName(a, b) : x === null ? 1 : -1;
    return y - x || byName(a, b);
  });
}

// ── words ──────────────────────────────────────────────────────────────────

/** "Stock", "ETF", "Fund"; null when the broker doesn't say. */
export function assetLabel(assetClass: string | null | undefined): string | null {
  return assetClass === "stock" ? "Stock" : assetClass === "etf" ? "ETF" : assetClass === "fund" ? "Fund" : null;
}

/** What a position is, in one line: "ACMEAD · NSE" or "ETF · NIFTYBEES · BSE"; a fund "Equity · Northwind Mutual Fund". */
export function positionLine(p: Pick<BrokerPosition, "asset_class" | "symbol" | "exchange" | "category" | "issuer" | "isin">): string {
  const parts =
    p.asset_class === "fund"
      ? [p.category, p.issuer]
      : [p.asset_class === "etf" ? "ETF" : null, p.symbol && p.symbol !== p.isin ? p.symbol : null, p.exchange];
  const line = parts.filter((x): x is string => !!x && x.trim() !== "").join(" · ");
  return line || p.isin || "";
}

/** The price and its date: "INR 193.83 NAV on 27 Oct" for a fund, else "INR 240.05". */
export function priceLine(p: Pick<BrokerPosition, "price" | "price_date" | "asset_class">, currency: string): string {
  const price = p.price ? `${currency.toUpperCase()} ${trimPrice(p.price)}` : "—";
  if (p.asset_class === "fund") return p.price_date ? `${price} NAV on ${formatDate(p.price_date, "short")}` : `${price} NAV`;
  return price;
}

/** A unit price as stored ("193.82730000") for display: grouped, 2–4 decimals ("193.8273", "240.05"). */
export function trimPrice(v: string): string {
  const n = Number(v);
  if (!Number.isFinite(n)) return v;
  return new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4 }).format(n);
}

const ordinal = (n: number) => {
  const t = n % 100;
  if (t >= 11 && t <= 13) return `${n}th`;
  return `${n}${({ 1: "st", 2: "nd", 3: "rd" } as Record<number, string>)[n % 10] ?? "th"}`;
};

/** "INR 2,184 monthly, on the 5th"; without a day, "INR 2,184 monthly". */
export function sipSchedule(s: Pick<Sip, "amount" | "currency" | "frequency" | "day">): string {
  const amount = formatTotal(s.amount, { currency: s.currency || "INR" });
  const freq = s.frequency ? ` ${s.frequency}` : "";
  const day = Number(s.day);
  const on = s.frequency === "monthly" && Number.isInteger(day) && day >= 1 && day <= 31 ? `, on the ${ordinal(day)}` : "";
  return `${amount}${freq}${on}`;
}

const MONTH = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** Zerodha's step-up ({"10-02": 3}: 3% more each year from 2 Oct): "Steps up 3% every 2 Oct"; null without one. */
export function sipStepUp(stepUp: Sip["step_up"]): string | null {
  const [entry] = Object.entries(stepUp ?? {});
  if (!entry) return null;
  const [key, pct] = entry;
  const m = /^(\d{2})-(\d{2})$/.exec(key);
  const rate = Number(pct);
  if (!m || !Number.isFinite(rate) || rate <= 0) return null;
  const month = MONTH[Number(m[1]) - 1];
  return month ? `Steps up ${rate}% every ${Number(m[2])} ${month}` : null;
}

/** An instant's date in India (an Indian instalment is dated as Zerodha dates it); null when absent. */
export function istDay(at: string | null | undefined): string | null {
  const t = at ? Date.parse(at) : NaN;
  if (!Number.isFinite(t)) return null;
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata", year: "numeric", month: "2-digit", day: "2-digit" }).format(t);
}

/** A SIP's state in a few words, and its tone: a rejected instalment is a warning. */
export function sipStatus(s: Pick<Sip, "status" | "missed" | "last_order" | "completed" | "next_instalment">): { text: string; tone: "danger" | "muted" | "positive" } {
  if (s.missed) {
    const why = s.last_order?.message?.trim();
    const day = istDay(s.last_order?.at);
    const which = day ? `The ${formatDate(day, "short")} instalment was` : "The last instalment was";
    return { text: `${which} rejected${why ? `: ${why.replace(/\.$/, "")}` : ""}`, tone: "danger" };
  }
  if (s.status === "paused") return { text: "Paused", tone: "muted" };
  if (s.status === "cancelled") return { text: "Cancelled", tone: "muted" };
  if (s.status !== "active") return { text: "Not active", tone: "muted" };
  const done = Number(s.completed);
  const count = Number.isInteger(done) && done > 0 ? `${done} instalment${done === 1 ? "" : "s"} so far` : "Active";
  const next = s.next_instalment ? ` · next ${formatDate(s.next_instalment, "short")}` : "";
  return { text: `${count}${next}`, tone: "positive" };
}

// ── allocation ─────────────────────────────────────────────────────────────

/** Each slice with its colour (the chart palette, in the server's order) and its width for the bar. */
export function allocationBars(slices: readonly AllocationSlice[]): (AllocationSlice & { color: string; width: number })[] {
  return slices.map((s, i) => ({ ...s, color: `var(--chart-cat-${(i % 16) + 1})`, width: Math.max(0, Math.min(100, toAmount(s.weight_pct) ?? 0)) }));
}

// ── one position ───────────────────────────────────────────────────────────

export interface PositionDay {
  as_of: string;
  price: string | null;
  price_date: string | null;
  quantity: string | null;
  value: string | null;
  cost: string | null;
}

export interface PositionDetail {
  account_code: string;
  provider: string;
  isin: string;
  holding_code: string | null;
  name: string;
  symbol: string | null;
  currency: string;
  last_marked_on: string | null;
  /** As the account shows it; null once it is no longer held. */
  position: BrokerPosition | null;
  series: PositionDay[];
  sips: Sip[];
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown) => (typeof v === "string" ? v : null);

/** broker_position_detail's jsonb; null when the account never marked that ISIN (or the payload isn't one). */
export function parsePositionDetail(raw: unknown): PositionDetail | null {
  if (!isObject(raw) || typeof raw.account_code !== "string" || typeof raw.isin !== "string") return null;
  const series = Array.isArray(raw.series) ? raw.series.filter(isObject) : [];
  return {
    account_code: raw.account_code,
    provider: str(raw.provider) ?? "broker",
    isin: raw.isin,
    holding_code: str(raw.holding_code),
    name: str(raw.name) ?? raw.isin,
    symbol: str(raw.symbol),
    currency: str(raw.currency) ?? "INR",
    last_marked_on: str(raw.last_marked_on),
    position: isObject(raw.position) && typeof raw.position.name === "string" ? (raw.position as unknown as BrokerPosition) : null,
    series: series
      .filter((d) => typeof d.as_of === "string")
      .map((d) => ({ as_of: d.as_of as string, price: str(d.price), price_date: str(d.price_date), quantity: str(d.quantity), value: str(d.value), cost: str(d.cost) }))
      .sort((a, b) => a.as_of.localeCompare(b.as_of)),
    sips: parseSips(raw.sips),
  };
}

/** A position's marks as the portfolio chart's points: its worth against what it cost, each day. */
export function positionPoints(series: readonly PositionDay[]): PortfolioPoint[] {
  return series.map((d) => ({
    date: d.as_of,
    marked: toAmount(d.value),
    estimated: null,
    deposits: toAmount(d.cost),
    isEstimated: false,
    day: { as_of: d.as_of, total: d.value, cash: null, positions: d.value, net_deposits: null, invested: d.cost, estimated: false },
  }));
}
