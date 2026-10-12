import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type RpcReturn } from "@/lib/supabase";
import { toAmount } from "@/lib/money";
import { formatMonth } from "@/lib/dates";
import { keys } from "./keys";
import { must, mustList } from "./api";

/**
 * Every budget of the ledger as it stands in `month`: the ones that count
 * (`is_effective`, total first) and, after them, the ones that don't
 * (upcoming, ended, or replaced by a newer budget of the same scope). Which
 * budget counts is the server's call (CLAUDE.md §2.2).
 */
export function useBudgetStatus(profileCode: string, month: string) {
  return useQuery({
    queryKey: keys.budgetStatus(profileCode, month),
    queryFn: async () =>
      mustList(await supabase.rpc("budget_status", { p_profile_code: profileCode, p_month: month, p_include_inactive: true })),
  });
}

export interface BudgetInput {
  budget_code?: string;
  /** null: every card. */
  account_code: string | null;
  category_code: string | null;
  amount_aed: string;
  effective_from: string;
  effective_to: string | null;
}

/** Validate a budget form. Returns an error sentence or null. */
export function validateBudget(b: BudgetInput): string | null {
  if (!/^\d+(\.\d{1,2})?$/.test(b.amount_aed.trim()) || Number(b.amount_aed) <= 0) return "Enter an amount above zero, e.g. 1500 or 1500.50.";
  if (!/^\d{4}-\d{2}-01$/.test(b.effective_from)) return "A budget starts on the first of a month.";
  if (b.effective_to && b.effective_to < b.effective_from) return "The end month must be after the start month.";
  return null;
}

export function useSaveBudget(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (b: BudgetInput) => {
      const row = {
        account_code: b.account_code,
        category_code: b.category_code,
        // numeric column: PostgREST accepts the decimal string as-is.
        amount_aed: b.amount_aed.trim() as unknown as number,
        effective_from: b.effective_from,
        effective_to: b.effective_to,
      };
      if (b.budget_code) return must(await supabase.from("budgets").update(row).eq("budget_code", b.budget_code));
      return must(await supabase.from("budgets").insert({ ...row, profile_code: profileCode }));
    },
    onSettled: () => qc.invalidateQueries({ queryKey: ["p", profileCode, "budgets"] }),
  });
}

export function useDeleteBudget(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (code: string) => must(await supabase.from("budgets").delete().eq("budget_code", code)),
    onSettled: () => qc.invalidateQueries({ queryKey: ["p", profileCode, "budgets"] }),
  });
}

export type BudgetStatusRow = RpcReturn<"budget_status">[number];
export type BudgetTone = "positive" | "warn" | "danger";

/**
 * Meter tone for a budget, from server figures: over budget is danger; 80%+
 * used, or on pace to overspend this month, is a warning.
 */
export function budgetTone(
  b: Pick<BudgetStatusRow, "share_used" | "projected_aed" | "budget_aed">,
  isCurrentMonth: boolean,
): BudgetTone {
  const share = toAmount(b.share_used) ?? 0;
  if (share > 1) return "danger";
  if (share >= 0.8) return "warn";
  const projected = toAmount(b.projected_aed);
  const budget = toAmount(b.budget_aed);
  if (isCurrentMonth && projected !== null && budget !== null && projected > budget) return "warn";
  return "positive";
}

/** Whether a month (first-of-month date) is before, at, or after today's month. */
export function monthPhase(month: string, today: string): "past" | "current" | "future" {
  const m = month.slice(0, 7);
  const t = today.slice(0, 7);
  return m < t ? "past" : m > t ? "future" : "current";
}

/** "2026-10" (an <input type="month"> value) → "2026-10-01"; invalid → "". */
export function monthInputToDate(v: string): string {
  return /^\d{4}-(0[1-9]|1[0-2])$/.test(v) ? `${v}-01` : "";
}

/** "2026-10-01" → "2026-10" for an <input type="month">. */
export function dateToMonthInput(d: string | null | undefined): string {
  return d && /^\d{4}-\d{2}/.test(d) ? d.slice(0, 7) : "";
}

/**
 * A budget's name from its scope: the category (or "All spending"), and for a
 * card budget the card too. `categoryName` is the server's ("All spending" when
 * there is no category); `accountName` is null for an every-card budget.
 */
export function budgetTitle(b: { category_code: string | null; category_name: string; account_name: string | null }): string {
  if (!b.account_name) return b.category_name;
  return b.category_code === null ? b.account_name : `${b.category_name} · ${b.account_name}`;
}

/** Splits `budget_status` rows by the server's `is_effective`, keeping its order. */
export function splitByEffective<T extends { is_effective: boolean }>(rows: readonly T[]): { effective: T[]; inactive: T[] } {
  return { effective: rows.filter((r) => r.is_effective), inactive: rows.filter((r) => !r.is_effective) };
}

/**
 * Why a budget the server marked not effective for `month` (a first-of-month
 * date) doesn't count: it starts later, it ended, or, when its own range does
 * cover the month, a newer budget of the same scope replaced it.
 */
export function inactiveBudgetLabel(b: { effective_from: string; effective_to: string | null }, month: string): string {
  if (b.effective_from > month) return `Starts ${formatMonth(b.effective_from)}`;
  if (b.effective_to && b.effective_to < month) return `Ended ${formatMonth(b.effective_to)}`;
  return "Replaced by a newer budget";
}

/**
 * The edit form's starting values for a `budget_status` row. The generated
 * row type can't say so, but the codes and `effective_to` are null for an
 * every-card, all-spending or open-ended budget.
 */
export function budgetDraft(b: {
  budget_code: string;
  account_code: string | null;
  category_code: string | null;
  budget_aed: number | string;
  effective_from: string;
  effective_to: string | null;
}): BudgetInput {
  return {
    budget_code: b.budget_code,
    account_code: b.account_code ?? null,
    category_code: b.category_code ?? null,
    amount_aed: String(b.budget_aed),
    effective_from: b.effective_from,
    effective_to: b.effective_to ?? null,
  };
}
