import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type RpcReturn } from "@/lib/supabase";
import type { DateRange } from "@/lib/dates";
import type { Grain, SpendGroup } from "@/lib/search";
import type { TrendFilters } from "@/lib/trend-filters";
import { keys } from "./keys";
import { must, mustList } from "./api";

export type { Grain, SpendGroup };
export type SpendSeriesRow = RpcReturn<"spend_series">[number];

function rangeArgs(profileCode: string, r: DateRange) {
  return { p_profile_code: profileCode, p_from: r.from, p_to: r.to };
}

/** Filter arguments shared by spend_series and spend_breakdown. All optional: omitted = everything. */
export interface SpendFilterArgs {
  p_category_codes?: string[];
  p_bank_codes?: string[];
  p_card_codes?: string[];
  p_q?: string;
  p_instruments?: string[];
}

/**
 * RPC filter arguments for the Trends filters. Empty lists and a blank search
 * are left out, so an unfiltered call sends exactly what it did before. Lists
 * are sorted: selection order does not change the result, so it must not change
 * the query key either.
 */
export function spendFilterArgs(f: TrendFilters | undefined): SpendFilterArgs {
  if (!f) return {};
  const out: SpendFilterArgs = {};
  if (f.categories.length) out.p_category_codes = [...f.categories].sort();
  if (f.banks.length) out.p_bank_codes = [...f.banks].sort();
  if (f.cards.length) out.p_card_codes = [...f.cards].sort();
  const q = f.q?.trim();
  if (q) out.p_q = q;
  if (f.instrument) out.p_instruments = [f.instrument];
  return out;
}

/**
 * Spend over time. With `top`, the server folds groups outside the top N (by
 * total over the whole range) into one "Other" group (group_key null).
 */
export function useSpendSeries(profileCode: string, range: DateRange, grain: Grain, group: SpendGroup, top?: number, enabled = true, filters?: TrendFilters) {
  const filterArgs = spendFilterArgs(filters);
  return useQuery({
    queryKey: keys.analytics(profileCode, "series", range, grain, group, top ?? null, filterArgs),
    enabled,
    placeholderData: keepPreviousData,
    queryFn: async () =>
      mustList(
        await supabase.rpc("spend_series", {
          ...rangeArgs(profileCode, range),
          p_grain: grain,
          p_group: group,
          ...(top ? { p_top: top } : {}),
          ...filterArgs,
        }),
      ),
  });
}

export function useCategoryBreakdown(profileCode: string, range: DateRange) {
  return useQuery({
    queryKey: keys.analytics(profileCode, "categories", range),
    placeholderData: keepPreviousData,
    queryFn: async () => mustList(await supabase.rpc("category_breakdown", rangeArgs(profileCode, range))),
  });
}

export function useMerchantLeaderboard(profileCode: string, range: DateRange, limit = 20) {
  return useQuery({
    queryKey: keys.analytics(profileCode, "merchants", range, limit),
    placeholderData: keepPreviousData,
    queryFn: async () =>
      mustList(await supabase.rpc("merchant_leaderboard", { ...rangeArgs(profileCode, range), p_limit: limit })),
  });
}

export function useDailySpend(profileCode: string, range: DateRange) {
  return useQuery({
    queryKey: keys.analytics(profileCode, "daily", range),
    placeholderData: keepPreviousData,
    queryFn: async () => mustList(await supabase.rpc("daily_spend", rangeArgs(profileCode, range))),
  });
}

export function useHourWeekday(profileCode: string, range: DateRange) {
  return useQuery({
    queryKey: keys.analytics(profileCode, "hours", range),
    placeholderData: keepPreviousData,
    queryFn: async () => mustList(await supabase.rpc("hour_weekday_pattern", rangeArgs(profileCode, range))),
  });
}

export function useFxSpend(profileCode: string, range: DateRange) {
  return useQuery({
    queryKey: keys.analytics(profileCode, "fx", range),
    placeholderData: keepPreviousData,
    queryFn: async () => mustList(await supabase.rpc("fx_spend", rangeArgs(profileCode, range))),
  });
}

export function useYoy(profileCode: string, year: number) {
  return useQuery({
    queryKey: keys.analytics(profileCode, "yoy", year),
    placeholderData: keepPreviousData,
    queryFn: async () => mustList(await supabase.rpc("yoy_compare", { p_profile_code: profileCode, p_year: year })),
  });
}

export function useAnomalies(profileCode: string, range: DateRange) {
  return useQuery({
    queryKey: keys.analytics(profileCode, "anomalies", range),
    placeholderData: keepPreviousData,
    queryFn: async () => mustList(await supabase.rpc("anomalies", rangeArgs(profileCode, range))),
  });
}

/**
 * "This is fine": the owner dismisses an unusual charge for good (dismiss_anomaly). The
 * server leaves it out of anomalies from then on and dismisses its insight, so both refetch.
 */
export function useDismissAnomaly(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (txnCode: string) =>
      must(await supabase.rpc("dismiss_anomaly", { p_profile_code: profileCode, p_txn_code: txnCode })),
    onSettled: () =>
      Promise.all([
        qc.invalidateQueries({ queryKey: keys.analytics(profileCode, "anomalies") }),
        qc.invalidateQueries({ queryKey: keys.insights(profileCode) }),
      ]),
  });
}

export function useRecurring(profileCode: string) {
  return useQuery({
    queryKey: keys.analytics(profileCode, "recurring"),
    queryFn: async () => mustList(await supabase.rpc("recurring_list", { p_profile_code: profileCode })),
  });
}

export interface SeriesPivot {
  /** One row per bucket: { bucket, [seriesKey]: amount } */
  rows: Record<string, number | string>[];
  /** Legend order: largest first, the server's "Other" group last. */
  groups: { key: string; label: string; color_token: string | null; total: number }[];
}

/** Series key for the server's folded "Other" group. */
export const OTHER_KEY = "__other";

/**
 * Chart key for a spend_series row. Rows without a group_key (uncategorised,
 * unknown merchant) are told apart by label; the server's folded group
 * (group_key null, label "Other") gets OTHER_KEY. Keys are chart dataKeys, so
 * labels are encoded to keep "." and "[" from reading as property paths.
 */
export function seriesKey(r: { group_key: string | null; group_label: string | null }): string {
  if (r.group_key) return r.group_key;
  if (r.group_label === "Other") return OTHER_KEY;
  return `label_${encodeURIComponent(r.group_label ?? "").replace(/\./g, "%2E")}`;
}

/**
 * Pivot spend_series rows into chart rows. Grouping and top-N folding happen on
 * the server (p_top); amounts are passed through for plotting, and the summed
 * totals only order the legend.
 */
export function pivotSeries(rows: SpendSeriesRow[]): SeriesPivot {
  const groups = new Map<string, { key: string; label: string; color_token: string | null; total: number }>();
  const byBucket = new Map<string, Record<string, number | string>>();
  for (const r of rows) {
    const key = seriesKey(r);
    const g = groups.get(key) ?? { key, label: r.group_label ?? "Uncategorised", color_token: r.color_token ?? null, total: 0 };
    g.total += Number(r.amount);
    groups.set(key, g);
    const row = byBucket.get(r.bucket) ?? { bucket: r.bucket };
    row[key] = Number(r.amount);
    byBucket.set(r.bucket, row);
  }
  return {
    rows: [...byBucket.values()].sort((a, b) => String(a.bucket).localeCompare(String(b.bucket))),
    groups: [...groups.values()].sort((a, b) => Number(a.key === OTHER_KEY) - Number(b.key === OTHER_KEY) || b.total - a.total),
  };
}

// ── spend_breakdown ──────────────────────────────────────────────────────────
export const BREAKDOWN_GROUPS = ["category", "bank", "merchant"] as const;
export type BreakdownGroupBy = (typeof BREAKDOWN_GROUPS)[number];
/** The server's folded "everything outside the top N" group ("Others"), always last. */
export const BREAKDOWN_OTHER_KEY = "__other__";
/** Groups kept by the server before folding the rest into "Others". */
export const BREAKDOWN_TOP_N = 10;

export interface SpendBreakdownGroup {
  /** category_code (or "__uncategorized__"), bank_code, merchant_code (or "__unknown__"), or "__other__". */
  key: string;
  label: string;
  color_token: string | null;
  logo_path: string | null;
  /** Decimal string. */
  total: string;
  /** Share of the range total, decimal string 0–1 (4 dp). */
  share: string;
}

/** spend_breakdown(...) result (generated as Json; shape in ARCHITECTURE §6). Money is decimal strings. */
export interface SpendBreakdown {
  group_by: BreakdownGroupBy;
  total: string;
  /** Every month of the range, "YYYY-MM", oldest first. */
  months: string[];
  groups: SpendBreakdownGroup[];
  /** One row per month; `values` carries every group key, zero-filled. */
  series: { month: string; total: string; values: Record<string, string> }[];
}

/** Monthly spend split by category, bank or merchant: top N plus "Others", computed on the server from v_spend. */
export function useSpendBreakdown(profileCode: string, range: DateRange, groupBy: BreakdownGroupBy, topN = BREAKDOWN_TOP_N, filters?: TrendFilters) {
  const filterArgs = spendFilterArgs(filters);
  return useQuery({
    queryKey: keys.analytics(profileCode, "breakdown", range, groupBy, topN, filterArgs),
    placeholderData: keepPreviousData,
    queryFn: async () =>
      must(
        await supabase.rpc("spend_breakdown", {
          ...rangeArgs(profileCode, range),
          p_group_by: groupBy,
          p_top_n: topN,
          ...filterArgs,
        }),
      ) as unknown as SpendBreakdown,
  });
}
