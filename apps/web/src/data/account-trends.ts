// Cards → compare accounts (MA-2): each account's statement balances and utilisation, from
// statement_cycles, and its monthly spend, from spend_series grouped by account. Every figure
// is the server's; the helpers below only group and order rows for the sparklines.
import { useQuery } from "@tanstack/react-query";
import { supabase, type RpcArgs } from "@/lib/supabase";
import { addMonths, monthStart, todayDubai, type DateRange, type ISODate } from "@/lib/dates";
import { toAmount, type MoneyInput } from "@/lib/money";
import { keys } from "./keys";
import { mustList } from "./api";
import type { StatementCycle } from "./cards";
import type { SpendSeriesRow } from "./analytics";

/** Statements per account in the balance and utilisation sparklines. */
export const COMPARISON_STATEMENTS = 12;
/** Months of spend per account. */
export const COMPARISON_MONTHS = 12;
/**
 * statement_cycles rows fetched (newest first): a year of statements for 30 accounts. The
 * comparison keeps the newest COMPARISON_STATEMENTS of each.
 */
export const CYCLE_HISTORY_LIMIT = 360;

/** Every statement's balance and utilisation, newest first (shares the statements cache prefix). */
export function useCycleHistory(profileCode: string) {
  const args: RpcArgs<"statement_cycles"> = { p_profile_code: profileCode, p_limit: CYCLE_HISTORY_LIMIT };
  return useQuery({
    queryKey: [...keys.cycles(profileCode), "history", CYCLE_HISTORY_LIMIT],
    queryFn: async () => mustList(await supabase.rpc("statement_cycles", args)),
  });
}

/** The comparison's spend window: the last COMPARISON_MONTHS whole months, this one included. */
export function comparisonRange(today: ISODate = todayDubai(), months = COMPARISON_MONTHS): DateRange {
  const m = monthStart(today);
  return { from: addMonths(m, -(months - 1)), to: today };
}

/** Month starts from `from`'s month to `to`'s month, oldest first. */
export function monthsBetween(from: ISODate, to: ISODate): ISODate[] {
  const out: ISODate[] = [];
  for (let m = monthStart(from); m <= to && out.length < 240; m = addMonths(m, 1)) out.push(m);
  return out;
}

export interface StatementPoint {
  stmt_code: string;
  statement_date: string;
  /** Server values, passed through for display and plotting. */
  closing_balance: MoneyInput;
  utilisation: MoneyInput;
  credit_limit: MoneyInput;
}

/**
 * Per account, its newest `perAccount` card statements, oldest first (sparkline order). History
 * exports (kind ≠ "statement") are not monthly statements and are left out.
 */
export function statementTrends(cycles: StatementCycle[], perAccount = COMPARISON_STATEMENTS): Map<string, StatementPoint[]> {
  const out = new Map<string, StatementPoint[]>();
  const sorted = [...cycles].filter((c) => c.kind === "statement").sort((a, b) => b.statement_date.localeCompare(a.statement_date));
  for (const c of sorted) {
    const list = out.get(c.account_code) ?? [];
    if (list.length >= perAccount) continue;
    list.push({ stmt_code: c.stmt_code, statement_date: c.statement_date, closing_balance: c.closing_balance, utilisation: c.utilisation, credit_limit: c.credit_limit });
    out.set(c.account_code, list);
  }
  for (const list of out.values()) list.reverse();
  return out;
}

export interface MonthPoint {
  month: ISODate;
  /** The server's amount for the month; 0 when the server returned no row (nothing spent). */
  amount: MoneyInput;
}

/**
 * Per account, one point per month of `months`, from spend_series rows grouped by account. A
 * month with no row had no spend, so it is 0. Rows without an account are left out.
 */
export function monthlySpendByAccount(rows: SpendSeriesRow[], months: ISODate[]): Map<string, MonthPoint[]> {
  const byAccount = new Map<string, Map<string, MoneyInput>>();
  for (const r of rows) {
    if (!r.group_key) continue;
    const m = byAccount.get(r.group_key) ?? new Map<string, MoneyInput>();
    m.set(r.bucket.slice(0, 10), r.amount);
    byAccount.set(r.group_key, m);
  }
  const out = new Map<string, MonthPoint[]>();
  for (const [account, m] of byAccount) out.set(account, months.map((month) => ({ month, amount: m.get(month) ?? 0 })));
  return out;
}

/** Sparkline values for server amounts; a missing amount is a gap (null), not zero. */
export function sparkValues(values: MoneyInput[]): (number | null)[] {
  return values.map((v) => toAmount(v));
}
