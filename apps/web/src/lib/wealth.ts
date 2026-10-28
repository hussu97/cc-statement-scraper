// Wealth mode display helpers: the account pages' search and chart points, ledger
// amounts and flow filters. Pure, unit-tested. Every figure is the server's (net_worth,
// account_ledger, bank_balance_series): nothing here adds money up (CLAUDE.md §2.2).
import { addDays, addMonths, isISODate, monthStart, todayDubai, type ISODate } from "./dates";
import { formatMoney, formatTotal, toAmount, type MoneyInput } from "./money";
import type { Flow } from "./cash-flow";

// ── the account pages' search (?month=YYYY-MM, ?tab=) ──────────────────────

/** A month param (`YYYY-MM`) no later than this one; undefined otherwise. */
function monthParam(m: unknown, today: ISODate): string | undefined {
  if (typeof m !== "string" || !/^\d{4}-\d{2}$/.test(m) || !isISODate(`${m}-01`)) return undefined;
  return `${m}-01` <= today ? m : undefined;
}

/**
 * `/wealth/accounts/$accountCode?month=YYYY-MM`: a month no later than this one. Every account
 * page is a bank account's, so `tab` (the broker tabs it once had) is returned as undefined: the
 * router lays validated search over the raw URL, and an old `?tab=` must not survive.
 */
export function parseAccountSearch(raw: Record<string, unknown>, today: ISODate = todayDubai()): { month?: string; tab?: undefined } {
  return { month: monthParam(raw.month, today), tab: undefined };
}

/** A synced broker account's portfolio tabs (?tab=); Portfolio is the default and stays out of the URL. */
export const PORTFOLIO_TABS = ["portfolio", "transactions", "past"] as const;
export type PortfolioTab = (typeof PORTFOLIO_TABS)[number];

export function portfolioTab(raw: string | undefined): PortfolioTab {
  return (PORTFOLIO_TABS as readonly string[]).includes(raw ?? "") ? (raw as PortfolioTab) : "portfolio";
}

/**
 * `/wealth/investments/accounts/$accountCode?tab=…&month=YYYY-MM`: a known tab other than the
 * default, and the Transactions tab's month; dropped keys are undefined.
 */
export function parsePortfolioSearch(raw: Record<string, unknown>, today: ISODate = todayDubai()): { month?: string; tab?: PortfolioTab } {
  const tab = typeof raw.tab === "string" && portfolioTab(raw.tab) !== "portfolio" ? portfolioTab(raw.tab) : undefined;
  return { month: monthParam(raw.month, today), tab };
}

/** The first of the month a `?month=` names, this month when absent. */
export function accountMonthStart(month: string | undefined, today: ISODate = todayDubai()): ISODate {
  return month ? `${month}-01` : monthStart(today);
}

/** A first-of-month as the URL's `YYYY-MM`; undefined for this month (the default). */
export function accountMonthParam(start: ISODate, today: ISODate = todayDubai()): string | undefined {
  return start === monthStart(today) ? undefined : start.slice(0, 7);
}

/** The previous or next month's `?month=` value (undefined = this month). */
export function shiftAccountMonth(start: ISODate, by: number, today: ISODate = todayDubai()): string | undefined {
  return accountMonthParam(addMonths(start, by), today);
}

// ── ledger rows ────────────────────────────────────────────────────────────

/** A ledger amount from the account's side: "+AED 50,000.00" in, "−AED 1,500.00" out. "—" when unpriced. */
export function formatLedgerAmount(amount: MoneyInput, direction: string | null | undefined, currency = "AED"): string {
  const n = toAmount(amount);
  if (n === null) return "—";
  return formatMoney(direction === "debit" ? -Math.abs(n) : Math.abs(n), { currency, signed: true });
}

/** A period's money in or out (a total, so whole units): "+AED 50,000" / "−AED 1,500"; "AED 0" when nothing moved. */
export function formatInOut(amount: MoneyInput, direction: "in" | "out", currency = "AED"): string {
  const n = toAmount(amount);
  if (n === null) return "—";
  return formatTotal(direction === "out" ? -n : n, { currency, signed: true });
}

/** The ledger's display filter (client-side: it hides rows, it never totals them). */
export const LEDGER_FILTERS = [
  { value: "all", label: "All", flows: null },
  { value: "in", label: "Money in", flows: ["income", "money_in"] },
  { value: "committed", label: "Support & saving", flows: ["support", "saving"] },
  { value: "spent", label: "Spent", flows: ["spend", "spend_transfer"] },
  { value: "unfiled", label: "Unfiled", flows: ["money_in", "money_out"] },
  { value: "moves", label: "Moves", flows: ["card_repayment", "internal_in", "internal_out"] },
] as const satisfies readonly { value: string; label: string; flows: readonly Flow[] | null }[];
export type LedgerFilter = (typeof LEDGER_FILTERS)[number]["value"];

export function matchesLedgerFilter(flow: string | null | undefined, filter: LedgerFilter): boolean {
  const f = LEDGER_FILTERS.find((x) => x.value === filter);
  if (!f || f.flows === null) return true;
  return !!flow && (f.flows as readonly string[]).includes(flow);
}

/** The filters worth offering for these rows: All, plus each one that matches a row. */
export function availableLedgerFilters(rows: readonly { flow: string | null }[]): (typeof LEDGER_FILTERS)[number][] {
  return LEDGER_FILTERS.filter((f) => f.flows === null || rows.some((r) => matchesLedgerFilter(r.flow, f.value)));
}

export function accountKindLabel(kind: string | null | undefined): string {
  return kind === "savings" ? "Savings account" : kind === "credit_card" ? "Credit card" : "Current account";
}

/** Activity's tag for a purchase on a bank account's debit card; null for a card row. */
export function debitTag(accountKind: string | null | undefined): "Debit" | null {
  return accountKind === "current" || accountKind === "savings" ? "Debit" : null;
}

// ── balance chart ──────────────────────────────────────────────────────────

/** Days of balance history on the account page. */
export const BALANCE_DAYS = 90;

export function balanceRange(today: ISODate = todayDubai()): { from: ISODate; to: ISODate } {
  return { from: addDays(today, -(BALANCE_DAYS - 1)), to: today };
}

export interface BalancePoint {
  date: ISODate;
  /** For plotting only (display): null is a gap, before the first evidence. */
  balance: number | null;
}

/** bank_balance_series as chart points; a null or unreadable balance stays a gap. */
export function balancePoints(series: readonly { date: string; balance: MoneyInput }[]): BalancePoint[] {
  return series.map((p) => ({ date: p.date.slice(0, 10), balance: toAmount(p.balance) }));
}

/** Whether a series has anything to plot. */
export function hasBalances(points: readonly BalancePoint[]): boolean {
  return points.some((p) => p.balance !== null);
}

// ── net worth ──────────────────────────────────────────────────────────────

/** Where a card's owed figure comes from, without a date (net_worth.cards carries none). */
export function cardAnchorNote(anchor: string | null | undefined): string {
  if (anchor === "statement") return "Last statement + activity since";
  if (anchor === "balance_migration") return "Card replaced + activity since";
  return "No balance from the bank yet";
}

export interface NetWorthPoint {
  month: ISODate;
  as_of: ISODate;
  /** For plotting only (display). */
  net: number | null;
  cash: number | null;
  holdings: number | null;
  owed: number | null;
  is_live: boolean;
}

export function netWorthPoints(
  series: readonly {
    month: string;
    as_of: string;
    net_aed: MoneyInput;
    cash_aed: MoneyInput;
    holdings_aed?: MoneyInput;
    owed_aed: MoneyInput;
    is_live: boolean;
  }[],
): NetWorthPoint[] {
  return series.map((p) => ({
    month: p.month.slice(0, 10),
    as_of: p.as_of.slice(0, 10),
    net: toAmount(p.net_aed),
    cash: toAmount(p.cash_aed),
    holdings: toAmount(p.holdings_aed),
    owed: toAmount(p.owed_aed),
    is_live: p.is_live,
  }));
}

/** Months of history before today's live figure: the chart needs at least one to draw a line. */
export function netWorthHistoryMonths(points: readonly { is_live: boolean }[]): number {
  return points.filter((p) => !p.is_live).length;
}
