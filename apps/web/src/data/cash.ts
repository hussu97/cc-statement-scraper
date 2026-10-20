// Bank balances and cash flow (Phase 2d): public.cash_position, public.cash_flow,
// create_bank_account and record_balance. The server computes every figure (CLAUDE.md §2.2).
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import type { BankAccountKind, CashFlowRow } from "@/lib/cash-flow";
import { keys, LEDGER_DOMAINS, type Domain } from "./keys";
import { ApiError, errorMessage, must, mustList } from "./api";

export interface CashAccount {
  account_code: string;
  bank_code: string;
  kind: BankAccountKind;
  nickname: string | null;
  account_ref: string | null;
  currency: string;
  /** In the account's currency, a decimal string; null when no balance was ever recorded. */
  balance: string | null;
  balance_aed: string | null;
  as_of: string | null;
  anchor_source: "manual" | "sms" | null;
  /** The balance is over 7 days old. */
  is_stale: boolean;
  /** Transactions since the balance without an AED amount (left out of balance_aed). */
  unpriced_count: number;
}

/** public.cash_position: active bank accounts and the AED total (cash_position returns Json in the generated types). */
export interface CashPosition {
  total_aed: string;
  /** Every account has an AED balance and every amount since it is priced. */
  complete: boolean;
  stale_count: number;
  missing_count: number;
  /** The oldest balance's as-of; null when none is recorded. */
  as_of: string | null;
  accounts: CashAccount[];
}

export function useCashPosition(profileCode: string) {
  return useQuery({
    queryKey: keys.cashPosition(profileCode),
    queryFn: async () => must(await supabase.rpc("cash_position", { p_profile_code: profileCode })) as unknown as CashPosition,
  });
}

/** public.cash_flow over [from, to]: each month's flows and its net, amounts as positive magnitudes. */
export function useCashFlow(profileCode: string, range: { from: string; to: string }) {
  return useQuery({
    queryKey: keys.cashFlow(profileCode, range.from, range.to),
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<CashFlowRow[]> =>
      mustList(await supabase.rpc("cash_flow", { p_profile_code: profileCode, p_from: range.from, p_to: range.to })),
  });
}

/** What a new account or balance changes: balances, cash flow, the overview tile, filters and (re-run SMS) transactions. */
const CASH_DOMAINS: Domain[] = [...LEDGER_DOMAINS, "meta"];

function invalidateCash(qc: ReturnType<typeof useQueryClient>, profileCode: string, domains: readonly Domain[]) {
  return Promise.all(domains.map((d) => qc.invalidateQueries({ queryKey: ["p", profileCode, d] })));
}

export interface NewBankAccount {
  bank_code: string;
  kind: BankAccountKind;
  /** Digits only, or "" when unknown. */
  account_ref: string;
  nickname: string;
}

export function useCreateBankAccount(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (a: NewBankAccount) =>
      must(
        await supabase.rpc("create_bank_account", {
          p_profile_code: profileCode,
          p_bank_code: a.bank_code,
          p_kind: a.kind,
          p_account_ref: a.account_ref,
          ...(a.nickname.trim() ? { p_nickname: a.nickname.trim() } : {}),
        }),
      ),
    // Adding an account re-runs its bank's earlier alerts, so transactions may appear too.
    onSettled: () => invalidateCash(qc, profileCode, CASH_DOMAINS),
  });
}

export function useRecordBalance(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { account_code: string; balance: string; as_of: string | null }) =>
      must(
        await supabase.rpc("record_balance", {
          p_profile_code: profileCode,
          p_account_code: v.account_code,
          p_balance: v.balance,
          ...(v.as_of ? { p_as_of: v.as_of } : {}),
        }),
      ),
    onSettled: () => invalidateCash(qc, profileCode, ["cash", "overview"]),
  });
}

function codeOf(e: unknown): string | undefined {
  return e instanceof ApiError ? e.code : typeof e === "object" && e && "code" in e ? String((e as { code: unknown }).code) : undefined;
}

/** create_bank_account's errors in plain words. Pure, unit-tested. */
export function bankAccountErrorMessage(e: unknown): string {
  switch (codeOf(e)) {
    case "23505":
      return "This ledger already has an account at that bank ending in those digits.";
    case "22023":
      return "Enter the last 3–12 digits of the account number, as the bank's alerts show them.";
    case "P0002":
      return "That bank isn't available. Pick another.";
    case "42501":
      return "Only the ledger's owner can add bank accounts.";
    default:
      return errorMessage(e) || "Couldn't add the account. Try again.";
  }
}

/** record_balance's errors in plain words. Pure, unit-tested. */
export function balanceErrorMessage(e: unknown): string {
  switch (codeOf(e)) {
    case "22023":
      return /future/i.test(errorMessage(e))
        ? "A balance can't be dated in the future."
        : "Enter the balance as a number with at most two decimals, e.g. 12500 or -40.25.";
    case "P0002":
      return "That account isn't a bank account in this ledger any more.";
    case "42501":
      return "Only the ledger's owner can record balances.";
    default:
      return errorMessage(e) || "Couldn't save the balance. Try again.";
  }
}
