// Investments (Wealth mode): holdings of every kind, metal prices, flows, values, returns and links.
// holdings_valuation, holding_detail, holding_returns, holdings_value_series and
// cash_flow_savings return jsonb (Json in the generated types), so the shapes are declared here
// from the migrations (20261021070429_metal_prices_and_holdings.sql,
// 20261021093154_holdings_flows_and_returns.sql).
// Money and prices are decimal strings; the server computes every figure (CLAUDE.md §2.2).
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type RpcArgs } from "@/lib/supabase";
import type { HoldingInput } from "@/lib/holdings";
import type { FlowFormInput, InvestmentInput, ReturnFigures, ReturnPeriod, SavingRow } from "@/lib/investments";
import { keys, LEDGER_DOMAINS } from "./keys";
import { ApiError, errorMessage, must } from "./api";

export interface MetalPrice {
  aed_per_gram: string;
  as_of: string;
  /** Percent (×100) since the price 24 hours earlier; null without one. */
  change_24h_pct: string | null;
  is_stale: boolean;
}

export interface Holding {
  holding_code: string;
  name: string;
  /** metal | plan | broker | security | deposit | structured_note | savings_account (lib/investments HOLDING_KINDS); absent from an older server (metals only). */
  kind?: string;
  /** The holding's own currency; metals are AED. */
  currency?: string;
  institution?: string | null;
  /** Metals only from here to image_path; null for every other kind. */
  metal: "gold" | "silver" | null;
  grams: string | null;
  karat: number | null;
  /** 24K only, parts per 10,000 (9999 | 9995 | 9990 | 9950). */
  fineness: number | null;
  /** Silver only, a fraction ("0.9990"). */
  purity: string | null;
  form: "bar" | "coin" | "jewellery" | null;
  /** Object name in the public `investment-images` bucket, `<metal>-<form>.jpg`; null for non-metals. */
  image_path: string | null;
  /** Shares and funds: units held and the ticker. */
  units?: string | null;
  symbol?: string | null;
  /** Deposits: principal (own currency), profit rate in percent a year, maturity date. A savings account may state its rate too. */
  principal?: string | null;
  rate_pct?: string | null;
  maturity_on?: string | null;
  /** Payments whose description contains it are linked automatically. */
  link_pattern?: string | null;
  /** The whole description must equal link_pattern (ignoring case), not just contain it. */
  link_exact?: boolean;
  /** What it cost: contributions − withdrawals in AED; null with no flows. */
  cost_aed: string | null;
  income_aed?: string | null;
  /** A metal's purchase date, a deposit's start, else when the plan or account began. */
  acquired_on: string | null;
  notes: string | null;
  /** The metal_prices quote that values it (gold_24k … silver_retail); null for non-metals. */
  quote: string | null;
  aed_per_gram: string | null;
  price_as_of: string | null;
  /** Metal: price over 3 days old; plan, broker, share: value over 45 days old. */
  price_is_stale: boolean;
  /** Value in the holding's currency; null when unknown. */
  value?: string | null;
  /** The day the value is as of. */
  value_as_of?: string | null;
  /** Deposits: the value is an estimate (principal + profit accrued so far). */
  is_estimate?: boolean;
  flow_count?: number;
  /** Null with no price or value yet. */
  value_aed: string | null;
  gain_aed: string | null;
  /** Percent (×100) of cost. */
  gain_pct: string | null;
  /** Meaningful for metals only. */
  change_24h_aed: string | null;
}

/** public.holdings_valuation: the ledger's active holdings valued now, with totals and the latest prices. */
export interface HoldingsValuation {
  value_aed: string;
  cost_aed: string | null;
  gain_aed: string | null;
  gain_pct: string | null;
  change_24h_aed: string | null;
  complete: boolean;
  costs_complete: boolean;
  stale_count: number;
  holdings_count: number;
  prices: Partial<Record<string, MetalPrice>>;
  holdings: Holding[];
}

export function useHoldingsValuation(profileCode: string) {
  return useQuery({
    queryKey: keys.holdings(profileCode),
    queryFn: async () => {
      const args: RpcArgs<"holdings_valuation"> = { p_profile_code: profileCode };
      return must(await supabase.rpc("holdings_valuation", args)) as unknown as HoldingsValuation;
    },
  });
}

export interface HoldingsDay {
  date: string;
  /** The holdings that had a price or value that day, summed; null with none. */
  value_aed: string | null;
  /** False when some holding had no value that day: value_aed is part of the total. Absent from an older server. */
  complete?: boolean;
  cost_aed: string | null;
}

export function useHoldingsValueSeries(profileCode: string, range: { from: string; to: string }) {
  return useQuery({
    queryKey: keys.holdingsSeries(profileCode, range.from, range.to),
    queryFn: async () => {
      const args: RpcArgs<"holdings_value_series"> = { p_profile_code: profileCode, p_from: range.from, p_to: range.to };
      return must(await supabase.rpc("holdings_value_series", args)) as unknown as HoldingsDay[];
    },
  });
}

/**
 * A holding change moves the Investments page and net worth (under "cash"), and a linked payment
 * leaves spend for saving: every ledger domain that counts transactions refreshes.
 */
function invalidateWealth(qc: ReturnType<typeof useQueryClient>, profileCode: string) {
  return Promise.all(LEDGER_DOMAINS.map((d) => qc.invalidateQueries({ queryKey: keys.domain(profileCode, d) })));
}

/** save_holding's arguments for a metal (HoldingInput) or any other kind (InvestmentInput). Pure, unit-tested. */
export function saveHoldingArgs(profileCode: string, h: HoldingInput | InvestmentInput): RpcArgs<"save_holding"> {
  const args: RpcArgs<"save_holding"> = { p_profile_code: profileCode, p_name: h.name };
  if (h.holding_code) args.p_holding_code = h.holding_code;
  if (h.acquired_on !== undefined) args.p_acquired_on = h.acquired_on;
  if (h.notes !== undefined) args.p_notes = h.notes;
  if (isInvestmentInput(h)) {
    args.p_kind = h.kind;
    args.p_currency = h.currency;
    if (h.institution !== undefined) args.p_institution = h.institution;
    if (h.link_pattern !== undefined) args.p_link_pattern = h.link_pattern;
    if (h.link_exact !== undefined) args.p_link_exact = h.link_exact;
    if (h.units !== undefined) args.p_units = h.units;
    if (h.symbol !== undefined) args.p_symbol = h.symbol;
    if (h.principal !== undefined) args.p_principal = h.principal;
    if (h.rate_pct !== undefined) args.p_rate_pct = h.rate_pct;
    if (h.maturity_on !== undefined) args.p_maturity_on = h.maturity_on;
    return args;
  }
  args.p_kind = "metal";
  args.p_metal = h.metal;
  args.p_grams = h.grams;
  args.p_form = h.form;
  if (h.karat !== undefined) args.p_karat = h.karat;
  if (h.fineness !== undefined) args.p_fineness = h.fineness;
  if (h.purity !== undefined) args.p_purity = h.purity;
  if (h.cost_aed !== undefined) args.p_cost_aed = h.cost_aed;
  return args;
}

function isInvestmentInput(h: HoldingInput | InvestmentInput): h is InvestmentInput {
  return "kind" in h && h.kind !== undefined && h.kind !== "metal";
}

export function useSaveHolding(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (h: HoldingInput | InvestmentInput) => {
      const args = saveHoldingArgs(profileCode, h);
      return must(await supabase.rpc("save_holding", args)) as string;
    },
    onSettled: () => invalidateWealth(qc, profileCode),
  });
}

export function useCloseHolding(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (holdingCode: string) => {
      const args: RpcArgs<"close_holding"> = { p_profile_code: profileCode, p_holding_code: holdingCode };
      must(await supabase.rpc("close_holding", args));
    },
    onSettled: () => invalidateWealth(qc, profileCode),
  });
}

/** track_account_as_investment's arguments: the rate only when one is given (null leaves a stated one as it is). Pure, unit-tested. */
export function trackAccountArgs(profileCode: string, v: { accountCode: string; ratePct: string | null }): RpcArgs<"track_account_as_investment"> {
  const args: RpcArgs<"track_account_as_investment"> = { p_profile_code: profileCode, p_account_code: v.accountCode };
  if (v.ratePct !== null) args.p_rate_pct = v.ratePct;
  return args;
}

/**
 * Show a bank account under Investments as a savings_account holding (or change its stated rate:
 * the RPC is idempotent and reopens a closed one). Returns the holding's code. Its balance leaves
 * cash for holdings, so net worth, Accounts, Investments and returns all refresh.
 */
export function useTrackAccountAsInvestment(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { accountCode: string; ratePct: string | null }) =>
      must(await supabase.rpc("track_account_as_investment", trackAccountArgs(profileCode, v))) as string,
    onSettled: () => invalidateWealth(qc, profileCode),
  });
}

// ── one holding: flows, values, returns ────────────────────────────────────

export interface HoldingFlow {
  flow_code: string;
  flow_date: string;
  kind: "contribution" | "withdrawal" | "income";
  /** In the holding's currency. */
  amount: string;
  amount_aed: string;
  /** account: a savings account's own transaction (its transfers and interest). */
  source: "manual" | "rule" | "link" | "holding_cost" | "import" | "account";
  notes: string | null;
  txn_code: string | null;
  txn_description: string | null;
  txn_bank_code: string | null;
  txn_account_kind: string | null;
}

export interface HoldingValuation {
  valuation_code: string;
  as_of: string;
  /** Plan or broker account, in the holding's currency. */
  value: string | null;
  /** Share or fund: one unit's price. */
  unit_price: string | null;
  source: string;
}

/** public.holding_detail: active flows (with the paying transaction) and recorded values, newest first. */
export interface HoldingDetail {
  flows: HoldingFlow[];
  valuations: HoldingValuation[];
}

export function useHoldingDetail(profileCode: string, holdingCode: string) {
  return useQuery({
    queryKey: keys.holdingDetail(profileCode, holdingCode),
    retry: (n, e) => codeOf(e) !== "P0002" && n < 2,
    queryFn: async () => {
      const args: RpcArgs<"holding_detail"> = { p_profile_code: profileCode, p_holding_code: holdingCode };
      return must(await supabase.rpc("holding_detail", args)) as unknown as HoldingDetail;
    },
  });
}

export interface HoldingReturnRow extends ReturnFigures {
  holding_code: string;
  name: string;
  kind: string;
  from: string;
  to: string;
}

/** public.holding_returns: per holding and in total for all time, this year or the last 12 months. */
export interface HoldingReturns {
  period: ReturnPeriod;
  from: string | null;
  to: string;
  total: ReturnFigures;
  holdings: HoldingReturnRow[];
}

export function useHoldingReturns(profileCode: string, period: ReturnPeriod) {
  return useQuery({
    queryKey: keys.holdingReturns(profileCode, period),
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const args: RpcArgs<"holding_returns"> = { p_profile_code: profileCode, p_period: period };
      return must(await supabase.rpc("holding_returns", args)) as unknown as HoldingReturns;
    },
  });
}

export function useRecordHoldingValue(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { holding_code: string; value?: string; unit_price?: string; as_of?: string }) => {
      const args: RpcArgs<"record_holding_value"> = { p_profile_code: profileCode, p_holding_code: v.holding_code };
      if (v.value !== undefined) args.p_value = v.value;
      if (v.unit_price !== undefined) args.p_unit_price = v.unit_price;
      if (v.as_of !== undefined) args.p_as_of = v.as_of;
      return must(await supabase.rpc("record_holding_value", args)) as string;
    },
    onSettled: () => invalidateWealth(qc, profileCode),
  });
}

export function useAddHoldingFlow(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: FlowFormInput & { holding_code: string }) => {
      const args: RpcArgs<"add_holding_flow"> = {
        p_profile_code: profileCode,
        p_holding_code: v.holding_code,
        p_kind: v.kind,
        p_flow_date: v.flow_date,
        p_amount: v.amount,
      };
      if (v.amount_aed !== undefined) args.p_amount_aed = v.amount_aed;
      if (v.notes !== undefined) args.p_notes = v.notes;
      return must(await supabase.rpc("add_holding_flow", args)) as string;
    },
    onSettled: () => invalidateWealth(qc, profileCode),
  });
}

export function useRemoveHoldingFlow(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (flowCode: string) => {
      const args: RpcArgs<"remove_holding_flow"> = { p_profile_code: profileCode, p_flow_code: flowCode };
      must(await supabase.rpc("remove_holding_flow", args));
    },
    onSettled: () => invalidateWealth(qc, profileCode),
  });
}

/** Link a transaction to a holding (it becomes saving), or unlink it (null) for good. */
export function useLinkTransaction(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { txnCode: string; holdingCode: string | null }) => {
      const args: RpcArgs<"link_transaction"> = {
        p_profile_code: profileCode,
        p_txn_code: v.txnCode,
        // Null unlinks; the generated type marks it required.
        p_holding_code: v.holdingCode as string,
      };
      return must(await supabase.rpc("link_transaction", args)) as string | null;
    },
    onSettled: () => invalidateWealth(qc, profileCode),
  });
}

/** public.cash_flow_savings over [from, to]: saving per month by holding (null = filed by category only); `account` narrows it to one bank account. */
export function useCashFlowSavings(profileCode: string, range: { from: string; to: string }, account?: string) {
  return useQuery({
    queryKey: keys.cashFlowSavings(profileCode, range.from, range.to, account),
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const args: RpcArgs<"cash_flow_savings"> = { p_profile_code: profileCode, p_from: range.from, p_to: range.to };
      if (account) args.p_account_code = account;
      return must(await supabase.rpc("cash_flow_savings", args)) as unknown as SavingRow[];
    },
  });
}

function codeOf(e: unknown): string | undefined {
  return e instanceof ApiError ? e.code : typeof e === "object" && e && "code" in e ? String((e as { code: unknown }).code) : undefined;
}

/** Holding, value, flow and link errors in plain words. Pure, unit-tested. */
export function holdingErrorMessage(e: unknown): string {
  switch (codeOf(e)) {
    case "42501":
      return "Only the ledger's owner can change its investments.";
    case "P0002": {
      const m = errorMessage(e);
      if (/flow/i.test(m)) return "That entry was already removed. A metal's purchase cost is changed by editing the holding.";
      if (/transaction/i.test(m)) return "That transaction isn't in this ledger any more.";
      return "That holding isn't in this ledger any more, or it was closed.";
    }
    case "22023": {
      // The server's message names the field ("grams must be above 0"): readable as it is.
      const m = errorMessage(e);
      return m ? `${m.charAt(0).toUpperCase()}${m.slice(1)}.` : "Check the holding's details and try again.";
    }
    case "23514":
      return /link/i.test(errorMessage(e))
        ? "A link rule needs at least 3 characters, or 2 with Match the whole description on."
        : "Check the holding's details: one of them is out of range.";
    default:
      return errorMessage(e) || "Couldn't save the holding. Try again.";
  }
}
