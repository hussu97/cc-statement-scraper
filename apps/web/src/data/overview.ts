import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type Tables } from "@/lib/supabase";
import { keys } from "./keys";
import { must, mustList } from "./api";

export interface OverviewCategory {
  category_code: string | null;
  name: string | null;
  color_token: string | null;
  amount: number | string;
  txn_count: number;
}

export interface OverviewAccount {
  account_code: string;
  bank_code: string;
  nickname: string | null;
  product_name: string | null;
  credit_limit: string | null;
  last4: string | null;
  latest_statement: {
    stmt_code: string;
    statement_date: string;
    due_date: string | null;
    closing_balance: string | null;
    min_due: string | null;
  } | null;
  /** Latest statement balance / credit limit, 4dp decimal string (server-computed). */
  utilisation: string | null;
  unbilled_aed: string;
}

export interface OverviewRecent {
  txn_code: string;
  txn_date: string;
  txn_at: string | null;
  description: string;
  merchant_name: string | null;
  amount_aed: string | null;
  amount_original: string;
  currency_original: string;
  direction: "debit" | "credit";
  status: string;
  category_name: string | null;
  category_color: string | null;
  has_sms: boolean;
  has_statement: boolean;
}

export interface Overview {
  month: string;
  spend: string;
  spend_prev_month: string;
  spend_prev_month_to_date: string;
  spend_avg_3m: string;
  /** (spend − base) / base as a decimal string; base is last month to the same day (whole month for past months). Null when the base is 0. */
  change_vs_prev_month_to_date: string | null;
  /** (spend − 3-month average) / average as a decimal string; null when the average is 0. */
  change_vs_avg_3m: string | null;
  payments: string;
  pending_count: number;
  pending_amount: string;
  uncategorized_count: number;
  open_reviews: number;
  last_sms_at: string | null;
  top_categories: OverviewCategory[];
  accounts: OverviewAccount[];
  recent: OverviewRecent[];
}

export function useOverview(profileCode: string, month: string) {
  return useQuery({
    queryKey: keys.overview(profileCode, month),
    queryFn: async () =>
      must(await supabase.rpc("overview", { p_profile_code: profileCode, p_month: month })) as unknown as Overview,
  });
}

export type Insight = Tables<"insights">;

export function useInsights(profileCode: string) {
  return useQuery({
    queryKey: keys.insights(profileCode),
    queryFn: async () =>
      mustList(
        await supabase
          .from("insights")
          .select("*")
          .eq("profile_code", profileCode)
          .is("dismissed_at", null)
          .order("created_at", { ascending: false })
          .limit(20),
      ),
  });
}

/** Severity order for display: alerts first. */
export function sortInsights<T extends { severity: string; created_at: string }>(list: T[]): T[] {
  const rank: Record<string, number> = { alert: 0, warn: 1, info: 2 };
  return [...list].sort((a, b) => (rank[a.severity] ?? 3) - (rank[b.severity] ?? 3) || b.created_at.localeCompare(a.created_at));
}

export function useDismissInsight(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (code: string) =>
      must(await supabase.from("insights").update({ dismissed_at: new Date().toISOString() }).eq("insight_code", code)),
    onMutate: async (code) => {
      await qc.cancelQueries({ queryKey: keys.insights(profileCode) });
      const prev = qc.getQueryData<Insight[]>(keys.insights(profileCode));
      qc.setQueryData<Insight[]>(keys.insights(profileCode), (l) => l?.filter((i) => i.insight_code !== code));
      return { prev };
    },
    onError: (_e, _c, ctx) => ctx?.prev && qc.setQueryData(keys.insights(profileCode), ctx.prev),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.insights(profileCode) }),
  });
}

export interface FilterMeta {
  accounts: { account_code: string; bank_code: string; nickname: string | null; product_name: string | null }[];
  cards: { card_code: string; account_code: string; bank_code: string; last4: string; is_supplementary: boolean }[];
  categories: {
    category_code: string;
    name: string;
    kind: string;
    color_token: string | null;
    parent_code: string | null;
    archived: boolean;
  }[];
  banks: { bank_code: string; name: string }[];
  date_range: { min: string | null; max: string | null } | null;
}

export function useFilterMeta(profileCode: string) {
  return useQuery({
    queryKey: keys.filterMeta(profileCode),
    staleTime: 5 * 60_000,
    queryFn: async () => must(await supabase.rpc("filter_meta", { p_profile_code: profileCode })) as unknown as FilterMeta,
  });
}

/** Display label for an account: nickname, else "BANK product". */
export function accountLabel(a: { bank_code: string; nickname?: string | null; product_name?: string | null }): string {
  return a.nickname?.trim() || [a.bank_code, a.product_name].filter(Boolean).join(" · ");
}
