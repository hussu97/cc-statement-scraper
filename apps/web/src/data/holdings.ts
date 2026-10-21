// Investments (Wealth mode): gold and silver holdings and metal prices. holdings_valuation,
// holdings_value_series and metal_price_series return jsonb (Json in the generated types), so the
// shapes are declared here from the migration (20261021070429_metal_prices_and_holdings.sql).
// Money and prices are decimal strings; the server computes every figure (CLAUDE.md §2.2).
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type RpcArgs } from "@/lib/supabase";
import type { HoldingInput } from "@/lib/holdings";
import { keys } from "./keys";
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
  metal: "gold" | "silver";
  grams: string;
  karat: number | null;
  /** 24K only, parts per 10,000 (9999 | 9995 | 9990 | 9950). */
  fineness: number | null;
  /** Silver only, a fraction ("0.9990"). */
  purity: string | null;
  form: "bar" | "coin" | "jewellery";
  /** Object name in the public `investment-images` bucket, `<metal>-<form>.jpg`. */
  image_path: string;
  cost_aed: string | null;
  acquired_on: string | null;
  notes: string | null;
  /** The metal_prices quote that values it (gold_24k … silver_retail). */
  quote: string;
  aed_per_gram: string | null;
  price_as_of: string | null;
  price_is_stale: boolean;
  /** Null with no price yet. */
  value_aed: string | null;
  gain_aed: string | null;
  /** Percent (×100) of cost. */
  gain_pct: string | null;
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
  /** Today's holdings at that day's prices; null when a holding had no price yet. */
  value_aed: string | null;
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

export interface PriceDay {
  date: string;
  aed_per_gram: string | null;
}

/** A quote's last price per Dubai day (global reference data, not per ledger). */
export function useMetalPriceSeries(quote: string, range: { from: string; to: string }, enabled = true) {
  return useQuery({
    queryKey: keys.metalPriceSeries(quote, range.from, range.to),
    enabled,
    queryFn: async () => {
      const args: RpcArgs<"metal_price_series"> = { p_quote: quote, p_from: range.from, p_to: range.to };
      return must(await supabase.rpc("metal_price_series", args)) as unknown as PriceDay[];
    },
  });
}

/** A holding changes the Investments page and net worth: both live under the "cash" domain. */
function invalidateWealth(qc: ReturnType<typeof useQueryClient>, profileCode: string) {
  return qc.invalidateQueries({ queryKey: keys.domain(profileCode, "cash") });
}

export function useSaveHolding(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (h: HoldingInput) => {
      const args: RpcArgs<"save_holding"> = { p_profile_code: profileCode, p_name: h.name, p_metal: h.metal, p_grams: h.grams, p_form: h.form };
      if (h.holding_code) args.p_holding_code = h.holding_code;
      if (h.karat !== undefined) args.p_karat = h.karat;
      if (h.fineness !== undefined) args.p_fineness = h.fineness;
      if (h.purity !== undefined) args.p_purity = h.purity;
      if (h.cost_aed !== undefined) args.p_cost_aed = h.cost_aed;
      if (h.acquired_on !== undefined) args.p_acquired_on = h.acquired_on;
      if (h.notes !== undefined) args.p_notes = h.notes;
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

function codeOf(e: unknown): string | undefined {
  return e instanceof ApiError ? e.code : typeof e === "object" && e && "code" in e ? String((e as { code: unknown }).code) : undefined;
}

/** save_holding / close_holding errors in plain words. Pure, unit-tested. */
export function holdingErrorMessage(e: unknown): string {
  switch (codeOf(e)) {
    case "42501":
      return "Only the ledger's owner can change its investments.";
    case "P0002":
      return "That holding isn't in this ledger any more.";
    case "22023": {
      // The server's message names the field ("grams must be above 0"): readable as it is.
      const m = errorMessage(e);
      return m ? `${m.charAt(0).toUpperCase()}${m.slice(1)}.` : "Check the holding's details and try again.";
    }
    case "23514":
      return "Check the holding's details: one of them is out of range.";
    default:
      return errorMessage(e) || "Couldn't save the holding. Try again.";
  }
}
