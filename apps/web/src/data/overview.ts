import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type Tables } from "@/lib/supabase";
import { keys } from "./keys";
import { must, mustList } from "./api";
import { formatRelative, todayDubai } from "@/lib/dates";
import type { BalanceAnchor } from "@/lib/balances";
import type { PaymentStatus } from "@/lib/dues";

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
    /** Server-matched payments against this statement (public.v_statement_payments); null when unknown. Optional: an older server omits it. */
    payment_status?: PaymentStatus | null;
    /** Card repayments after the statement date, a decimal string. Optional: an older server omits it. */
    amount_paid?: string | null;
  } | null;
  /** Latest statement balance / credit limit, 4dp decimal string (server-computed). */
  utilisation: string | null;
  unbilled_aed: string;
  /** What the card owes now (server-computed, v_account_balances); negative is a credit balance; null without an anchor. */
  outstanding_aed: string | null;
  balance_anchor: BalanceAnchor;
  balance_anchor_date: string | null;
  balance_has_estimate: boolean;
  balance_unpriced_count: number;
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
  /** The previous 3 months' spend up to the same day of the month, over 3 (WEB-26). Optional: an older server omits it. */
  spend_avg_3m_to_date?: string;
  /** Server projection for the month end (public.spend_pace); null for a future month. Optional: an older server omits it. */
  projected_month_end?: string | null;
  /** (spend − base) / base as a decimal string; base is last month to the same day (whole month for past months). Null when the base is 0. */
  change_vs_prev_month_to_date: string | null;
  /** (spend − 3-month average) / average as a decimal string; null when the average is 0. */
  change_vs_avg_3m: string | null;
  payments: string;
  /** What the active cards owe now; negative is a credit balance. */
  outstanding: string;
  /** Every active card has a balance anchor and every AED amount is known. */
  outstanding_complete: boolean;
  outstanding_has_estimate: boolean;
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

/**
 * Open insights fetched at most: the Overview panel shows the top five, the Insights feed all of
 * them. The nightly job dedupes by kind and key, so a ledger rarely has more than a few dozen.
 */
export const INSIGHTS_LIMIT = 100;

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
          // Expired insights hide at once, not after the nightly cleanup (WEB-45).
          .or(`valid_until.is.null,valid_until.gte.${todayDubai()}`)
          .order("created_at", { ascending: false })
          .limit(INSIGHTS_LIMIT),
      ),
  });
}

/** Where an insight card leads. `search` is the target screen's URL search. */
export type InsightTarget =
  | { to: "/budgets"; label: string }
  | { to: "/review"; label: string }
  | { to: "/cards"; search: { tab: "statements" }; label: string }
  | { to: "/insights"; search: { tab?: string }; label: string }
  | { to: "/insights/category/$categoryCode"; params: { categoryCode: string }; search: { range: "this_month" }; label: string }
  | { to: "/activity"; search: { category?: string; txn?: string }; label: string };

/**
 * Map an insight to the screen that answers it (WEB-25). Pure, unit-tested;
 * null for an unknown kind, so a new server kind never links somewhere wrong.
 */
export function insightTarget(i: Pick<Insight, "kind" | "data">): InsightTarget | null {
  const data = (i.data && typeof i.data === "object" && !Array.isArray(i.data) ? i.data : {}) as Record<string, unknown>;
  const str = (k: string) => (typeof data[k] === "string" && /^[a-z]{3}_[0-9a-z]{26}$/.test(data[k] as string) ? (data[k] as string) : undefined);
  switch (i.kind) {
    case "budget_risk":
      return { to: "/budgets", label: "See budgets" };
    case "statement_due":
      return { to: "/cards", search: { tab: "statements" }, label: "See statements" };
    case "price_change":
    case "new_recurring":
      return { to: "/insights", search: { tab: "subscriptions" }, label: "See subscriptions" };
    case "uncategorized":
      return { to: "/activity", search: { category: "none" }, label: "Categorise them" };
    case "category_spike": {
      // "So far this month": the category view for this month, with its trend and merchants (MA-1).
      const category = str("category_code");
      return category
        ? { to: "/insights/category/$categoryCode", params: { categoryCode: category }, search: { range: "this_month" }, label: "See the category" }
        : { to: "/insights", search: { tab: "categories" }, label: "See categories" };
    }
    case "large_transaction": {
      const txn = str("txn_code");
      return txn ? { to: "/activity", search: { txn }, label: "See transaction" } : { to: "/activity", search: {}, label: "See activity" };
    }
    case "review_backlog":
      return { to: "/review", label: "Open review" };
    case "spend_pace":
      return { to: "/insights", search: {}, label: "See trends" };
    default:
      return null;
  }
}

/**
 * Under the hero: when the last card alert (bank SMS or payment shortcut) arrived, so a person can
 * see capture is working. Null before the first one. Charges from alerts are transactions like any
 * other, so this line never counts them apart.
 */
export function lastCardAlertLabel(lastSmsAt: string | null, now: Date = new Date()): string | null {
  return lastSmsAt ? `Last card alert ${formatRelative(lastSmsAt, now)}` : null;
}

/** The Insights feed's sections (MA-5): which screen answers an insight, in display order. */
export const INSIGHT_GROUPS = [
  { key: "spending", label: "Spending", kinds: ["spend_pace", "category_spike", "large_transaction"] },
  { key: "budgets", label: "Budgets", kinds: ["budget_risk"] },
  { key: "subscriptions", label: "Subscriptions", kinds: ["price_change", "new_recurring"] },
  { key: "statements", label: "Statements", kinds: ["statement_due"] },
  { key: "tidy", label: "To tidy up", kinds: ["uncategorized", "review_backlog"] },
] as const;

export interface InsightGroup<T> {
  key: string;
  label: string;
  items: T[];
}

/**
 * Insights in feed sections, in INSIGHT_GROUPS order, each sorted alerts first; a kind the web
 * doesn't know yet lands in "Other" at the end rather than disappearing. Empty sections are left
 * out. Pure, unit-tested.
 */
export function groupInsights<T extends { kind: string; severity: string; created_at: string }>(list: T[]): InsightGroup<T>[] {
  const known = INSIGHT_GROUPS.map((g) => ({ key: g.key as string, label: g.label as string, kinds: g.kinds as readonly string[], items: [] as T[] }));
  const other: T[] = [];
  for (const i of list) (known.find((g) => g.kinds.includes(i.kind))?.items ?? other).push(i);
  return [...known, { key: "other", label: "Other", kinds: [], items: other }]
    .filter((g) => g.items.length > 0)
    .map((g) => ({ key: g.key, label: g.label, items: sortInsights(g.items) }));
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
