import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type Tables } from "@/lib/supabase";
import type { Json } from "@ledger/db-types";
import { addMonths, todayDubai } from "@/lib/dates";
import { keys, LEDGER_DOMAINS } from "./keys";
import { must, mustList } from "./api";

export type Category = Tables<"categories">;
export type Rule = Tables<"category_rules">;

export const CATEGORY_KINDS = [
  { value: "spend", label: "Spending" },
  { value: "income", label: "Income" },
  { value: "transfer", label: "Transfer" },
  { value: "fee", label: "Fee" },
  { value: "ignore", label: "Ignore" },
] as const;

export const MATCH_TYPES = [
  { value: "contains", label: "Contains" },
  { value: "prefix", label: "Starts with" },
  { value: "exact", label: "Is exactly" },
  { value: "regex", label: "Regex" },
] as const;

export const COLOR_TOKENS = Array.from({ length: 12 }, (_, i) => `cat-${i + 1}`);

export interface RuleConditions {
  amount_min?: string;
  amount_max?: string;
  bank_code?: string;
  currency?: string;
  kind?: string;
  direction?: string;
  /** Legacy/advanced: kept when editing, not editable in the UI. */
  card_code?: string;
}

/** Drop empty condition fields; amounts stay decimal strings. */
export function cleanConditions(c: RuleConditions): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(c)) {
    if (typeof v === "string" && v.trim() !== "") out[k] = k === "currency" ? v.trim().toUpperCase() : v.trim();
  }
  return out;
}

/** Validate a rule draft. Returns an error sentence or null. */
export function validateRule(d: { pattern: string; match_type: string; category_code: string; conditions: RuleConditions }): string | null {
  if (!d.category_code) return "Choose a category.";
  if (!d.pattern.trim()) return "Enter text to match.";
  if (d.match_type === "regex") {
    try {
      new RegExp(d.pattern);
    } catch {
      return "That regular expression isn't valid.";
    }
  }
  for (const k of ["amount_min", "amount_max"] as const) {
    const v = d.conditions[k]?.trim();
    if (v && !/^\d+(\.\d{1,2})?$/.test(v)) return "Amounts must be numbers like 50 or 49.99.";
  }
  return null;
}

/** Categories in display order with children under their parent. */
export function orderCategories<T extends { category_code: string; parent_code: string | null; sort_order: number; name: string }>(list: T[]): (T & { depth: number })[] {
  const byParent = new Map<string | null, T[]>();
  for (const c of list) {
    const p = c.parent_code && list.some((x) => x.category_code === c.parent_code) ? c.parent_code : null;
    byParent.set(p, [...(byParent.get(p) ?? []), c]);
  }
  const sort = (a: T, b: T) => a.sort_order - b.sort_order || a.name.localeCompare(b.name);
  const out: (T & { depth: number })[] = [];
  for (const top of (byParent.get(null) ?? []).sort(sort)) {
    out.push({ ...top, depth: 0 });
    for (const child of (byParent.get(top.category_code) ?? []).sort(sort)) out.push({ ...child, depth: 1 });
  }
  return out;
}

export function useCategories(profileCode: string) {
  return useQuery({
    queryKey: keys.categories(profileCode),
    queryFn: async () => mustList(await supabase.from("categories").select("*").eq("profile_code", profileCode)),
  });
}

function useInvalidateCategorisation(profileCode: string) {
  const qc = useQueryClient();
  return () =>
    Promise.all(
      [...LEDGER_DOMAINS, "categories", "rules", "meta"].map((d) => qc.invalidateQueries({ queryKey: ["p", profileCode, d] })),
    );
}

export function useSaveCategory(profileCode: string) {
  const invalidate = useInvalidateCategorisation(profileCode);
  return useMutation({
    mutationFn: async (c: {
      category_code?: string;
      name: string;
      kind: string;
      color_token: string | null;
      parent_code: string | null;
      archived_at?: string | null;
    }) => {
      const row = { name: c.name.trim(), kind: c.kind, color_token: c.color_token, parent_code: c.parent_code };
      if (c.category_code) {
        const patch = c.archived_at !== undefined ? { ...row, archived_at: c.archived_at } : row;
        return must(await supabase.from("categories").update(patch).eq("category_code", c.category_code));
      }
      return must(await supabase.from("categories").insert({ ...row, profile_code: profileCode }));
    },
    onSettled: invalidate,
  });
}

export function useArchiveCategory(profileCode: string) {
  const invalidate = useInvalidateCategorisation(profileCode);
  return useMutation({
    mutationFn: async (v: { categoryCode: string; archived: boolean }) =>
      must(
        await supabase
          .from("categories")
          .update({ archived_at: v.archived ? new Date().toISOString() : null })
          .eq("category_code", v.categoryCode),
      ),
    onSettled: invalidate,
  });
}

export function useRules(profileCode: string) {
  return useQuery({
    queryKey: keys.rules(profileCode),
    queryFn: async () =>
      mustList(
        await supabase
          .from("category_rules")
          .select("*")
          .eq("profile_code", profileCode)
          .order("priority")
          .order("created_at", { ascending: false }),
      ),
  });
}

export interface RuleDraft {
  rule_code?: string;
  name: string;
  category_code: string;
  match_type: string;
  pattern: string;
  priority: number;
  conditions: RuleConditions;
  active: boolean;
  source?: string;
}

export function useSaveRule(profileCode: string) {
  const invalidate = useInvalidateCategorisation(profileCode);
  return useMutation({
    mutationFn: async (d: RuleDraft) => {
      const row = {
        name: d.name.trim() || null,
        category_code: d.category_code,
        match_type: d.match_type,
        pattern: d.pattern.trim(),
        priority: d.priority,
        conditions: cleanConditions(d.conditions) as Json,
        active: d.active,
      };
      if (d.rule_code) return must(await supabase.from("category_rules").update(row).eq("rule_code", d.rule_code));
      return must(
        await supabase.from("category_rules").insert({ ...row, profile_code: profileCode, source: d.source ?? "user" }),
      );
    },
    onSettled: invalidate,
  });
}

export function useToggleRule(profileCode: string) {
  const invalidate = useInvalidateCategorisation(profileCode);
  return useMutation({
    mutationFn: async (v: { ruleCode: string; active: boolean }) =>
      must(await supabase.from("category_rules").update({ active: v.active }).eq("rule_code", v.ruleCode)),
    onSettled: invalidate,
  });
}

export function useDeleteRule(profileCode: string) {
  const invalidate = useInvalidateCategorisation(profileCode);
  return useMutation({
    mutationFn: async (ruleCode: string) => must(await supabase.from("category_rules").delete().eq("rule_code", ruleCode)),
    onSettled: invalidate,
  });
}

export interface RulePreview {
  matched: number;
  would_change: number;
  sample: { txn_code: string; description: string; amount_aed: string | null; txn_date: string; current_category_code: string | null }[];
}

export function useRulePreview(
  profileCode: string,
  args: { match_type: string; pattern: string; category_code: string; conditions: Record<string, string>; priority: number } | null,
) {
  return useQuery({
    queryKey: keys.rulePreview(profileCode, args),
    enabled: !!args && !!args.pattern.trim() && !!args.category_code,
    placeholderData: keepPreviousData,
    retry: false,
    queryFn: async () =>
      must(
        await supabase.rpc("preview_rule", {
          p_profile_code: profileCode,
          p_match_type: args!.match_type,
          p_pattern: args!.pattern,
          p_category_code: args!.category_code,
          p_conditions: args!.conditions as Json,
          p_priority: args!.priority,
        }),
      ) as unknown as RulePreview,
  });
}

export interface MerchantRow {
  merchant_code: string;
  merchant_name: string;
  category_code: string | null;
  category_name: string | null;
  /** Spend over the last 12 months; null when the merchant has none (it is listed for its assignment). */
  amount: number | null;
  txn_count: number | null;
  last_date: string | null;
  assignment: Tables<"merchant_profile_category"> | null;
}

/** merchant_leaderboard caps p_limit at 200 server-side. */
export const MERCHANT_LEADERBOARD_MAX = 200;

type Assignment = Tables<"merchant_profile_category"> & { merchants: { display_name: string } | null };
type BoardRow = { merchant_code: string | null; merchant_name: string; category_code: string | null; category_name: string | null; amount: number; txn_count: number; last_date: string };

/**
 * Leaderboard rows (top spend, last 12 months) plus every merchant with a
 * profile-level category or suggestion that fell outside it, so no assignment
 * or pending suggestion is ever hidden by the leaderboard cap (WEB-02). Pure.
 */
export function mergeMerchants(board: BoardRow[], assignments: Assignment[]): MerchantRow[] {
  const byCode = new Map(assignments.map((a) => [a.merchant_code, a]));
  const strip = (a: Assignment | undefined): Tables<"merchant_profile_category"> | null => {
    if (!a) return null;
    const { merchants: _m, ...rest } = a;
    return rest;
  };
  const rows: MerchantRow[] = board
    .filter((r): r is BoardRow & { merchant_code: string } => !!r.merchant_code)
    .map((r) => ({
      merchant_code: r.merchant_code,
      merchant_name: r.merchant_name,
      category_code: r.category_code,
      category_name: r.category_name,
      amount: r.amount,
      txn_count: r.txn_count,
      last_date: r.last_date,
      assignment: strip(byCode.get(r.merchant_code)),
    }));
  const seen = new Set(rows.map((r) => r.merchant_code));
  const extra = assignments
    .filter((a) => !seen.has(a.merchant_code))
    .map((a) => ({
      merchant_code: a.merchant_code,
      merchant_name: a.merchants?.display_name ?? a.merchant_code,
      category_code: a.category_code,
      category_name: null,
      amount: null,
      txn_count: null,
      last_date: null,
      assignment: strip(a),
    }))
    .sort((a, b) => a.merchant_name.localeCompare(b.merchant_name));
  return [...rows, ...extra];
}

/**
 * Merchants seen in the last 12 months (top 200 by spend) with their
 * profile-level category, plus every merchant that has an assignment.
 * `capped` is true when the leaderboard hit its server limit.
 */
export function useMerchants(profileCode: string) {
  return useQuery({
    queryKey: keys.merchants(profileCode),
    queryFn: async (): Promise<{ rows: MerchantRow[]; capped: boolean }> => {
      const today = todayDubai();
      const [board, mpc] = await Promise.all([
        supabase.rpc("merchant_leaderboard", {
          p_profile_code: profileCode,
          p_from: addMonths(today, -12),
          p_to: today,
          p_limit: MERCHANT_LEADERBOARD_MAX,
        }),
        supabase.from("merchant_profile_category").select("*, merchants(display_name)").eq("profile_code", profileCode),
      ]);
      const rows = mustList(board);
      return { rows: mergeMerchants(rows, mustList(mpc) as unknown as Assignment[]), capped: rows.length >= MERCHANT_LEADERBOARD_MAX };
    },
  });
}

/** One description seen for a merchant, to seed a rule pattern. */
export async function sampleDescription(profileCode: string, merchantCode: string): Promise<string | null> {
  const res = await supabase
    .from("transactions")
    .select("description")
    .eq("profile_code", profileCode)
    .eq("merchant_code", merchantCode)
    .order("txn_date", { ascending: false })
    .limit(1)
    .maybeSingle();
  return res.data?.description ?? null;
}

export function useSetMerchantCategory(profileCode: string) {
  const invalidate = useInvalidateCategorisation(profileCode);
  return useMutation({
    mutationFn: async (v: { merchantCode: string; categoryCode: string | null }) => {
      if (!v.categoryCode) {
        return must(
          await supabase.from("merchant_profile_category").delete().eq("profile_code", profileCode).eq("merchant_code", v.merchantCode),
        );
      }
      return must(
        await supabase.from("merchant_profile_category").upsert(
          {
            profile_code: profileCode,
            merchant_code: v.merchantCode,
            category_code: v.categoryCode,
            source: "manual",
            confidence: null,
            model: null,
          },
          { onConflict: "profile_code,merchant_code" },
        ),
      );
    },
    onSettled: invalidate,
  });
}

// ── pure helpers for the Rules screen ──────────────────────────────────────

export const RULE_TABS = ["categories", "rules", "merchants"] as const;
export type RuleTab = (typeof RULE_TABS)[number];

/** Tab from the URL, falling back to the first tab. */
export function ruleTab(v: string | undefined): RuleTab {
  return (RULE_TABS as readonly string[]).includes(v ?? "") ? (v as RuleTab) : "categories";
}

export const RULE_SOURCES: Record<string, string> = {
  seed: "Built-in",
  user: "Yours",
  llm_promoted: "From suggestion",
  legacy: "Imported",
};

/** Transaction kinds a rule condition can test (transactions.kind). */
export const TXN_KINDS = [
  { value: "purchase", label: "Purchase" },
  { value: "refund", label: "Refund" },
  { value: "payment", label: "Payment" },
  { value: "fee", label: "Fee" },
  { value: "interest", label: "Interest" },
  { value: "cash_advance", label: "Cash advance" },
  { value: "adjustment", label: "Adjustment" },
] as const;

export const DIRECTIONS = [
  { value: "debit", label: "Money out" },
  { value: "credit", label: "Money in" },
] as const;

/** "Contains 'COFFEE'" */
export function describeMatch(matchType: string, pattern: string): string {
  const label = MATCH_TYPES.find((m) => m.value === matchType)?.label ?? matchType;
  return `${label} ‘${pattern.trim()}’`;
}

/** jsonb conditions → editable strings. Unknown keys are kept so saving never drops them. */
export function parseConditions(raw: unknown): RuleConditions {
  const out: Record<string, string> = {};
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
      if (typeof v === "string" || typeof v === "number") out[k] = String(v);
    }
  }
  return out as RuleConditions;
}

/** Short phrases for a rule's extra conditions, e.g. ["AED 50 – 200", "FAB", "Money out"]. */
export function summarizeConditions(c: RuleConditions, bankName?: (code: string) => string): string[] {
  const out: string[] = [];
  const min = c.amount_min?.trim();
  const max = c.amount_max?.trim();
  if (min && max) out.push(`AED ${min} – ${max}`);
  else if (min) out.push(`AED ${min} or more`);
  else if (max) out.push(`Up to AED ${max}`);
  if (c.bank_code) out.push(bankName?.(c.bank_code) ?? c.bank_code);
  if (c.card_code) out.push("One card");
  if (c.currency) out.push(`In ${c.currency.toUpperCase()}`);
  if (c.kind) out.push(TXN_KINDS.find((k) => k.value === c.kind)?.label ?? c.kind);
  if (c.direction) out.push(DIRECTIONS.find((d) => d.value === c.direction)?.label ?? c.direction);
  return out;
}

export function emptyRuleDraft(patch: Partial<RuleDraft> = {}): RuleDraft {
  return { name: "", category_code: "", match_type: "contains", pattern: "", priority: 100, conditions: {}, active: true, ...patch };
}

export function ruleToDraft(r: Rule): RuleDraft {
  return {
    rule_code: r.rule_code,
    name: r.name ?? "",
    category_code: r.category_code,
    match_type: r.match_type,
    pattern: r.pattern,
    priority: r.priority,
    conditions: parseConditions(r.conditions),
    active: r.active,
    source: r.source,
  };
}

/** Arguments for preview_rule, or null when the draft can't be previewed yet. */
export function previewArgs(d: RuleDraft) {
  if (validateRule(d)) return null;
  return {
    match_type: d.match_type,
    pattern: d.pattern.trim(),
    category_code: d.category_code,
    conditions: cleanConditions(d.conditions),
    priority: Number.isFinite(d.priority) ? Math.trunc(d.priority) : 100,
  };
}

/** Rules matching a free-text query (pattern or name) and an optional category. */
export function filterRules<T extends Pick<Rule, "pattern" | "name" | "category_code">>(
  rules: T[],
  f: { q?: string; categoryCode?: string | null },
): T[] {
  const needle = f.q?.trim().toLowerCase() ?? "";
  return rules.filter(
    (r) =>
      (!f.categoryCode || r.category_code === f.categoryCode) &&
      (!needle || r.pattern.toLowerCase().includes(needle) || (r.name ?? "").toLowerCase().includes(needle)),
  );
}

/** One page of an in-memory list (pages are 1-based). */
export function slicePage<T>(list: T[], page: number, size: number): T[] {
  const from = (Math.max(1, page) - 1) * size;
  return list.slice(from, from + size);
}

/** Split categories into active (tree order) and archived (by name). */
export function groupCategories<T extends Category>(list: T[]): { active: (T & { depth: number })[]; archived: T[] } {
  const live = list.filter((c) => !c.archived_at);
  // Children of an archived parent still show, at top level.
  const active = orderCategories(live);
  const archived = list.filter((c) => !!c.archived_at).sort((a, b) => a.name.localeCompare(b.name));
  return { active, archived };
}

/** Rules per category code, for counts. */
export function countRulesByCategory(rules: Pick<Rule, "category_code">[]): Map<string, number> {
  const out = new Map<string, number>();
  for (const r of rules) out.set(r.category_code, (out.get(r.category_code) ?? 0) + 1);
  return out;
}

/** How a merchant's category is decided right now. */
export type MerchantState = "manual" | "suggested" | "rules";
export function merchantState(m: Pick<MerchantRow, "assignment">): MerchantState {
  if (m.assignment?.source === "manual") return "manual";
  if (m.assignment?.source === "llm") return "suggested";
  return "rules";
}

export function filterMerchants<T extends Pick<MerchantRow, "merchant_name" | "assignment">>(
  rows: T[],
  f: { q?: string; suggestionsOnly?: boolean },
): T[] {
  const needle = f.q?.trim().toLowerCase() ?? "";
  return rows.filter(
    (r) => (!f.suggestionsOnly || merchantState(r) === "suggested") && (!needle || r.merchant_name.toLowerCase().includes(needle)),
  );
}

/**
 * A rule pattern for a merchant: the merchant name when the bank description
 * contains it, else the description without trailing reference numbers.
 */
export function suggestPattern(description: string | null, merchantName: string): string {
  const name = merchantName.trim().toUpperCase();
  const desc = (description ?? "").trim().toUpperCase().replace(/\s+/g, " ");
  if (!desc) return name;
  if (name && desc.includes(name)) return name;
  const trimmed = desc.replace(/(\s+[#*]?\d[\d\s*#-]*)+$/, "").trim();
  return trimmed || desc;
}
