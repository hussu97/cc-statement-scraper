// Pure transforms for the monthly spend split (spend_breakdown). Unit-tested.
// Every total and share shown comes from the server; numbers are converted
// only to size the bars.
import { BREAKDOWN_OTHER_KEY, type BreakdownGroupBy, type SpendBreakdown } from "@/data/analytics";
import { displayRatio, toAmount } from "@/lib/money";
import { categoryVar, OTHER_FILL, rankToken } from "./palette";

export const SPLITS = ["none", "category", "bank", "merchant"] as const;
export type SpendSplit = (typeof SPLITS)[number];
export const SPLIT_LABEL: Record<SpendSplit, string> = { none: "Total", category: "Category", bank: "Bank", merchant: "Merchant" };

/** The spend_breakdown grouping that serves a split ("none" reads the month totals of any grouping). */
export function breakdownGroupFor(split: SpendSplit): BreakdownGroupBy {
  return split === "none" ? "category" : split;
}

/** The "Total" series when the bars are not split. */
export const TOTAL_KEY = "__total__";

export interface SplitSeries {
  /** Recharts dataKey: positional, so server keys never act as property paths. */
  dataKey: string;
  key: string;
  label: string;
  fill: string;
  logoPath: string | null;
  /** Server decimal strings, for display. */
  total: string;
  share: string;
}

export interface SplitRow {
  /** "YYYY-MM" */
  month: string;
  /** Server month total (decimal string), for the tooltip header. */
  monthTotal: string;
  /** Bar sizes by dataKey (display only). */
  [dataKey: string]: string | number;
}

export interface SplitChart {
  series: SplitSeries[];
  rows: SplitRow[];
  /** month → dataKey → server amount string, for tooltips. */
  raw: Map<string, Map<string, string>>;
  /** True when the range has no spend at all (the server said so). */
  empty: boolean;
}

/**
 * Bar colour for a group: a category keeps its own colour token (so it looks
 * the same on every chart); banks and merchants take the categorical palette
 * by rank; "Others" is neutral.
 */
export function splitFill(groupBy: BreakdownGroupBy, key: string, colorToken: string | null, index: number): string {
  if (key === BREAKDOWN_OTHER_KEY) return OTHER_FILL;
  if (groupBy === "category") return categoryVar(colorToken);
  return categoryVar(rankToken(index));
}

/** Shape a spend_breakdown answer for a stacked monthly bar chart. */
export function splitChart(b: SpendBreakdown, split: SpendSplit): SplitChart {
  const empty = b.groups.length === 0 || (toAmount(b.total) ?? 0) === 0;
  const series: SplitSeries[] =
    split === "none"
      ? [{ dataKey: "s0", key: TOTAL_KEY, label: "Spend", fill: "var(--color-accent)", logoPath: null, total: b.total, share: "1.0000" }]
      : b.groups.map((g, i) => ({
          dataKey: `s${i}`,
          key: g.key,
          label: g.label,
          fill: splitFill(b.group_by, g.key, g.color_token, i),
          logoPath: g.logo_path,
          total: g.total,
          share: g.share,
        }));
  const raw = new Map<string, Map<string, string>>();
  const rows: SplitRow[] = b.series.map((m) => {
    const row: SplitRow = { month: m.month, monthTotal: m.total };
    const cell = new Map<string, string>();
    for (const s of series) {
      const v = s.key === TOTAL_KEY ? m.total : (m.values[s.key] ?? "0.00");
      cell.set(s.dataKey, v);
      row[s.dataKey] = toAmount(v) ?? 0;
    }
    raw.set(m.month, cell);
    return row;
  });
  return { series, rows, raw, empty };
}

/** A group's share of one month's total, for the tooltip (display ratio of two server values). */
export function monthShare(value: string | undefined, monthTotal: string | undefined): number | null {
  const r = displayRatio(value, monthTotal);
  return r === null ? null : Math.max(0, Math.min(1, r));
}

/** "2026-09" → "2026-09-01", for the month formatters. */
export function monthDate(month: string): string {
  return /^\d{4}-\d{2}$/.test(month) ? `${month}-01` : month;
}

/**
 * Where a group's row in the totals list links: its transactions in Activity
 * for the range, when the group is a filter Activity understands.
 */
export function groupActivitySearch(groupBy: BreakdownGroupBy, key: string, from: string, to: string): { from: string; to: string; category?: string } | null {
  if (key === BREAKDOWN_OTHER_KEY) return null;
  if (groupBy === "category") return { from, to, category: key === "__uncategorized__" ? "none" : key };
  return null;
}
