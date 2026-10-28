// India mode (tasks/todo.md §12): Zerodha Kite and Zerodha Coin, apart from Wealth. A tolerant
// reader for india_overview's jsonb, the period and tab codecs, which tab an account belongs to,
// and the wording of its figures. INR first, AED under it. Every figure is the server's
// (CLAUDE.md §2.2): money stays a decimal string and becomes a number only to draw the chart.
// Pure, unit-tested.
import { formatTotal, toAmount, type MoneyInput } from "./money";
import { formatPct } from "./holdings";
import { DEFAULT_INVESTMENT_PERIOD, INVESTMENT_PERIODS, investmentPeriod, type InvestmentPeriod } from "./investments";
import { positionSort, positionSortParam, type PositionSort } from "./broker-detail";

// ── payload ────────────────────────────────────────────────────────────────

/** A decimal string as the server sent it ("12.50", "-3"), or null. */
export type Decimal = string | null;

export interface IndiaTotal {
  value: Decimal;
  value_aed: Decimal;
  invested: Decimal;
  cash: Decimal;
  pnl: Decimal;
  pnl_pct: Decimal;
  change_24h: Decimal;
  change_24h_aed: Decimal;
  change_24h_pct: Decimal;
  period_start_value: Decimal;
  period_end_value: Decimal;
  period_added: Decimal;
  period_growth: Decimal;
  period_growth_pct: Decimal;
  positions: Decimal;
  last_synced_at: string | null;
}

export interface IndiaAccount {
  account_code: string;
  bank_code: string | null;
  name: string;
  segment: string | null;
  value: Decimal;
  value_aed: Decimal;
  invested: Decimal;
  cash: Decimal;
  pnl: Decimal;
  pnl_pct: Decimal;
  change_24h: Decimal;
  change_24h_pct: Decimal;
  positions: Decimal;
  last_synced_at: string | null;
  sync_status: string | null;
}

export interface IndiaDay {
  date: string;
  value: Decimal;
  invested: Decimal;
}

export interface IndiaOverview {
  available: boolean;
  currency: string;
  period: InvestmentPeriod;
  from: string | null;
  to: string | null;
  total: IndiaTotal;
  accounts: IndiaAccount[];
  series: IndiaDay[];
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const DECIMAL = /^-?\d+(\.\d+)?$/;
/** Money and counts arrive as decimal strings; anything else (a float, junk) reads as unknown. */
const dec = (v: unknown): Decimal => (typeof v === "string" && DECIMAL.test(v.trim()) ? v.trim() : null);
const text = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v : null);
const ISO_DAY = /^\d{4}-\d{2}-\d{2}/;
const day = (v: unknown): string | null => (typeof v === "string" && ISO_DAY.test(v) ? v.slice(0, 10) : null);

const TOTAL_KEYS = [
  "value",
  "value_aed",
  "invested",
  "cash",
  "pnl",
  "pnl_pct",
  "change_24h",
  "change_24h_aed",
  "change_24h_pct",
  "period_start_value",
  "period_end_value",
  "period_added",
  "period_growth",
  "period_growth_pct",
  "positions",
] as const;

function readTotal(raw: unknown): IndiaTotal {
  const t = isObject(raw) ? raw : {};
  const out = Object.fromEntries(TOTAL_KEYS.map((k) => [k, dec(t[k])])) as Omit<IndiaTotal, "last_synced_at">;
  return { ...out, last_synced_at: text(t.last_synced_at) };
}

function readAccount(a: Record<string, unknown>): IndiaAccount | null {
  const code = text(a.account_code);
  if (!code) return null;
  const bank = text(a.bank_code);
  const segment = text(a.segment);
  return {
    account_code: code,
    bank_code: bank,
    name: text(a.name) ?? accountFallbackName(indiaSegment({ segment, bank_code: bank })),
    segment,
    value: dec(a.value),
    value_aed: dec(a.value_aed),
    invested: dec(a.invested),
    cash: dec(a.cash),
    pnl: dec(a.pnl),
    pnl_pct: dec(a.pnl_pct),
    change_24h: dec(a.change_24h),
    change_24h_pct: dec(a.change_24h_pct),
    positions: dec(a.positions),
    last_synced_at: text(a.last_synced_at),
    sync_status: text(a.sync_status),
  };
}

/**
 * india_overview's jsonb. Anything that isn't an overview reads as "no India" (available false,
 * empty lists), an account without a code or a day without a date is dropped, and the days are
 * sorted, so a partial payload still renders.
 */
export function parseIndiaOverview(raw: unknown): IndiaOverview {
  const r = isObject(raw) ? raw : {};
  const accounts = (Array.isArray(r.accounts) ? r.accounts : []).filter(isObject).flatMap((a) => readAccount(a) ?? []);
  const series = (Array.isArray(r.series) ? r.series : [])
    .filter(isObject)
    .flatMap((d) => {
      const date = day(d.date);
      return date ? [{ date, value: dec(d.value), invested: dec(d.invested) }] : [];
    })
    .sort((a, b) => a.date.localeCompare(b.date));
  return {
    available: r.available === true,
    currency: text(r.currency)?.toUpperCase() ?? "INR",
    period: investmentPeriod(r.period),
    from: day(r.from),
    to: day(r.to),
    total: readTotal(r.total),
    accounts: sortAccounts(accounts),
    series,
  };
}

// ── accounts and tabs ──────────────────────────────────────────────────────

export const INDIA_SEGMENTS = ["kite", "coin"] as const;
export type IndiaSegment = (typeof INDIA_SEGMENTS)[number];

export const INDIA_TAB: Record<IndiaSegment, { label: string; path: "/india/kite" | "/india/coin"; bankCode: string; holds: string }> = {
  kite: { label: "Kite", path: "/india/kite", bankCode: "KITE", holds: "Stocks and ETFs, and the Funds cash" },
  coin: { label: "Coin", path: "/india/coin", bankCode: "COIN", holds: "Mutual funds" },
};

/** Kite or Coin: the server's segment, else the bank (KITE, COIN); null for one that is neither. */
export function indiaSegment(a: { segment?: string | null; bank_code?: string | null }): IndiaSegment | null {
  const s = (a.segment ?? "").toLowerCase();
  if (s === "kite" || s === "coin") return s;
  const b = (a.bank_code ?? "").toUpperCase();
  return b === "KITE" ? "kite" : b === "COIN" ? "coin" : null;
}

/** The tab an account's row links to, or null when it is neither Kite nor Coin. */
export function indiaTabPath(a: { segment?: string | null; bank_code?: string | null }): "/india/kite" | "/india/coin" | null {
  const s = indiaSegment(a);
  return s ? INDIA_TAB[s].path : null;
}

/** The ledger's Kite (or Coin) account: the first one of that segment, or null. */
export function indiaAccountFor(accounts: readonly IndiaAccount[], segment: IndiaSegment): IndiaAccount | null {
  return accounts.find((a) => indiaSegment(a) === segment) ?? null;
}

function accountFallbackName(segment: IndiaSegment | null): string {
  return segment ? `Zerodha ${INDIA_TAB[segment].label}` : "Zerodha";
}

/** Kite first, then Coin, then anything else, as the server sends them. */
function sortAccounts(accounts: IndiaAccount[]): IndiaAccount[] {
  const rank = (a: IndiaAccount) => {
    const s = indiaSegment(a);
    return s ? INDIA_SEGMENTS.indexOf(s) : INDIA_SEGMENTS.length;
  };
  return accounts.map((a, i) => ({ a, i })).sort((x, y) => rank(x.a) - rank(y.a) || x.i - y.i).map((x) => x.a);
}

// ── search codecs ──────────────────────────────────────────────────────────

/** One period for the chart and the period returns: 30 days, 90 days, YTD, 365 days. */
export const INDIA_PERIODS = INVESTMENT_PERIODS;
export const DEFAULT_INDIA_PERIOD: InvestmentPeriod = DEFAULT_INVESTMENT_PERIOD;

/**
 * `/india?period=`: a known period other than the default, else undefined, explicitly: the router
 * lays validated search over the raw URL, so an unknown one must not survive (tasks/lessons.md).
 */
export function parseIndiaSearch(raw: Record<string, unknown>): { period?: InvestmentPeriod } {
  const p = investmentPeriod(raw.period);
  return { period: raw.period === p && p !== DEFAULT_INDIA_PERIOD ? p : undefined };
}

/** The `?period=` value for a choice: undefined for the default. */
export function indiaPeriodParam(p: InvestmentPeriod): InvestmentPeriod | undefined {
  return p === DEFAULT_INDIA_PERIOD ? undefined : p;
}

export const INDIA_ACCOUNT_TABS = ["portfolio", "past"] as const;
export type IndiaAccountTab = (typeof INDIA_ACCOUNT_TABS)[number];

export function indiaAccountTab(raw: unknown): IndiaAccountTab {
  return raw === "past" ? "past" : "portfolio";
}

/** `/india/kite?tab=past&sort=today`: Past, or undefined for the Portfolio default; the positions' sort, undefined for the default. */
export function parseIndiaAccountSearch(raw: Record<string, unknown>): { tab?: IndiaAccountTab; sort?: PositionSort } {
  const sort = positionSort(raw.sort);
  return { tab: indiaAccountTab(raw.tab) === "past" ? "past" : undefined, sort: raw.sort === sort ? positionSortParam(sort) : undefined };
}

// ── wording ────────────────────────────────────────────────────────────────

/** A total in the overview's currency (INR): "INR 123,456", whole units like every total. */
export function formatInr(value: MoneyInput, opts: { currency?: string; signed?: boolean; empty?: string } = {}): string {
  return formatTotal(value, { currency: opts.currency ?? "INR", signed: opts.signed, empty: opts.empty ?? "—" });
}

/** The AED line under an INR figure: "≈ AED 4,410", or why there is none. */
export function aedLine(valueAed: MoneyInput, opts: { signed?: boolean } = {}): string {
  return toAmount(valueAed) === null ? "No AED rate yet" : `≈ ${formatTotal(valueAed, { signed: opts.signed })}`;
}

/** "+INR 1,250 (+3.1%)": a P&L or a move with its percentage, both the server's; null when unknown. */
export function changeText(amount: MoneyInput, pct: MoneyInput, currency = "INR"): string | null {
  if (toAmount(amount) === null) return null;
  const p = formatPct(pct, { signed: true });
  return `${formatTotal(amount, { currency, signed: true })}${p ? ` (${p})` : ""}`;
}

/** The period-returns block: start value, added, growth (+%), each worded; "—" when unknown. */
export function periodFigures(t: Pick<IndiaTotal, "period_start_value" | "period_end_value" | "period_added" | "period_growth" | "period_growth_pct">, currency = "INR") {
  return {
    start: formatInr(t.period_start_value, { currency }),
    end: formatInr(t.period_end_value, { currency }),
    added: formatInr(t.period_added, { currency, signed: true }),
    growth: formatInr(t.period_growth, { currency, signed: true }),
    growthPct: formatPct(t.period_growth_pct, { signed: true }),
  };
}

/** "8 positions", "1 position"; null when the count is unknown. */
export function positionsText(n: MoneyInput): string | null {
  const c = toAmount(n);
  if (c === null) return null;
  return `${c} ${c === 1 ? "position" : "positions"}`;
}

// ── chart ──────────────────────────────────────────────────────────────────

export interface IndiaPoint {
  date: string;
  /** For drawing only: null is a gap, never a zero. */
  value: number | null;
  invested: number | null;
}

export function indiaPoints(series: readonly IndiaDay[]): IndiaPoint[] {
  return series.map((d) => ({ date: d.date, value: toAmount(d.value), invested: toAmount(d.invested) }));
}
