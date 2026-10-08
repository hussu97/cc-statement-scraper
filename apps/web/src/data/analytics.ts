import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { supabase, type RpcReturn } from "@/lib/supabase";
import type { DateRange } from "@/lib/dates";
import type { Grain, SpendGroup } from "@/lib/search";
import { keys } from "./keys";
import { mustList } from "./api";

export type { Grain, SpendGroup };
export type SpendSeriesRow = RpcReturn<"spend_series">[number];

function rangeArgs(profileCode: string, r: DateRange) {
  return { p_profile_code: profileCode, p_from: r.from, p_to: r.to };
}

/**
 * Spend over time. With `top`, the server folds groups outside the top N (by
 * total over the whole range) into one "Other" group (group_key null).
 */
export function useSpendSeries(profileCode: string, range: DateRange, grain: Grain, group: SpendGroup, top?: number) {
  return useQuery({
    queryKey: keys.analytics(profileCode, "series", range, grain, group, top ?? null),
    placeholderData: keepPreviousData,
    queryFn: async () =>
      mustList(
        await supabase.rpc("spend_series", {
          ...rangeArgs(profileCode, range),
          p_grain: grain,
          p_group: group,
          ...(top ? { p_top: top } : {}),
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
    const g = groups.get(key) ?? { key, label: r.group_label ?? "Uncategorized", color_token: r.color_token ?? null, total: 0 };
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
