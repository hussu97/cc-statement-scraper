// Wealth mode reads: net_worth, net_worth_series, account_ledger and bank_balance_series. Each
// returns jsonb (Json in the generated types), so the shapes are declared here from the migration
// (20261020162834_wealth_mode.sql). Money is a decimal string; the server computes every figure (§2.2).
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { supabase, type RpcArgs } from "@/lib/supabase";
import type { BalanceAnchor } from "@/lib/balances";
import { keys } from "./keys";
import { ApiError, must } from "./api";

export interface NetWorthCard {
  account_code: string;
  bank_code: string;
  nickname: string | null;
  product_name: string | null;
  /** What the card owes now (AED); null without a balance anchor. */
  outstanding_aed: string | null;
  anchor_kind: BalanceAnchor;
  has_estimate: boolean;
}

/** public.net_worth: bank cash − what the cards owe, with completeness. */
export interface NetWorth {
  cash_aed: string;
  cash_complete: boolean;
  cash_missing_count: number;
  cash_stale_count: number;
  /** The oldest bank balance's as-of; null when none is recorded. */
  cash_as_of: string | null;
  owed_aed: string;
  owed_complete: boolean;
  owed_has_estimate: boolean;
  net_aed: string;
  complete: boolean;
  has_bank_accounts: boolean;
  cards: NetWorthCard[];
}

export function useNetWorth(profileCode: string) {
  return useQuery({
    queryKey: keys.netWorth(profileCode),
    queryFn: async () => {
      const args: RpcArgs<"net_worth"> = { p_profile_code: profileCode };
      return must(await supabase.rpc("net_worth", args)) as unknown as NetWorth;
    },
  });
}

/** One month of public.net_worth_series: its last nightly snapshot, or (last) this month live. */
export interface NetWorthMonth {
  month: string;
  as_of: string;
  cash_aed: string;
  owed_aed: string;
  net_aed: string;
  complete: boolean;
  is_live: boolean;
}

export const NET_WORTH_MONTHS = 12;

export function useNetWorthSeries(profileCode: string, months = NET_WORTH_MONTHS) {
  return useQuery({
    queryKey: keys.netWorthSeries(profileCode, months),
    queryFn: async () => {
      const args: RpcArgs<"net_worth_series"> = { p_profile_code: profileCode, p_months: months };
      return must(await supabase.rpc("net_worth_series", args)) as unknown as NetWorthMonth[];
    },
  });
}

export interface LedgerAccount {
  account_code: string;
  bank_code: string;
  kind: "current" | "savings";
  nickname: string | null;
  account_ref: string | null;
  currency: string;
  status: string;
}

/** One row of public.account_ledger: a bank-statement line with its flow and running balance. */
export interface LedgerRow {
  txn_code: string;
  txn_date: string;
  txn_at: string | null;
  status: string;
  kind: string;
  direction: "debit" | "credit";
  description: string;
  merchant_code: string | null;
  merchant_name: string | null;
  /** Magnitude in the account's currency; null when it can't be priced in that currency. */
  amount: string | null;
  amount_aed: string | null;
  amount_original: string | null;
  currency_original: string | null;
  category_code: string | null;
  category_name: string | null;
  category_color: string | null;
  category_kind: string | null;
  category_source: string | null;
  /** The cash-flow flow (lib/cash-flow FLOWS); null when the row isn't in cash flow (void). */
  flow: string | null;
  /** Balance after this row, account currency; null before the first balance is known. */
  balance_after: string | null;
  notes: string | null;
  has_sms: boolean;
  transfer_txn_code: string | null;
  transfer_bank_code: string | null;
  transfer_card_last4: string | null;
}

/** public.account_ledger for [from, to]: rows newest first, opening/closing balance and money in/out. */
export interface AccountLedger {
  account: LedgerAccount;
  from: string;
  to: string;
  opening_balance: string | null;
  closing_balance: string | null;
  money_in: string;
  money_out: string;
  /** Rows with no amount in the account's currency (left out of every figure). */
  unpriced_count: number;
  rows: LedgerRow[];
}

export function useAccountLedger(profileCode: string, accountCode: string, range: { from: string; to: string }) {
  return useQuery({
    queryKey: keys.accountLedger(profileCode, accountCode, range.from, range.to),
    placeholderData: keepPreviousData,
    // Not found is an answer, not a blip: don't retry it.
    retry: (n, e) => !isNotFound(e) && n < 2,
    queryFn: async () => {
      const args: RpcArgs<"account_ledger"> = { p_profile_code: profileCode, p_account_code: accountCode, p_from: range.from, p_to: range.to };
      return must(await supabase.rpc("account_ledger", args)) as unknown as AccountLedger;
    },
  });
}

export interface BalanceDay {
  date: string;
  /** End-of-day balance (account currency); null before the first evidence. */
  balance: string | null;
}

export function useBankBalanceSeries(profileCode: string, accountCode: string, range: { from: string; to: string }) {
  return useQuery({
    queryKey: keys.balanceSeries(profileCode, accountCode, range.from, range.to),
    retry: (n, e) => !isNotFound(e) && n < 2,
    queryFn: async () => {
      const args: RpcArgs<"bank_balance_series"> = { p_profile_code: profileCode, p_account_code: accountCode, p_from: range.from, p_to: range.to };
      return must(await supabase.rpc("bank_balance_series", args)) as unknown as BalanceDay[];
    },
  });
}

/** account_ledger / bank_balance_series raise P0002 for an account that isn't a bank account of this ledger. */
export function isNotFound(e: unknown): boolean {
  const code = e instanceof ApiError ? e.code : typeof e === "object" && e && "code" in e ? String((e as { code: unknown }).code) : undefined;
  return code === "P0002";
}
