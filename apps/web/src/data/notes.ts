// Structured notes (20261027124257_structured_notes.sql) and typed account entries.
// structured_notes_summary and structured_note_detail return jsonb (Json in the generated types),
// so their shapes are declared here from the migration. Every figure is the server's
// (private.note_evaluate, CLAUDE.md §2.2); numbers are decimal strings, seq and days are counts.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type RpcArgs } from "@/lib/supabase";
import type { CallScenario, MarketQuote, PayoutBranch } from "@/lib/notes";
import type { NoteShare, NoteVerdict } from "@/lib/note-verdict";
import { keys, LEDGER_DOMAINS } from "./keys";
import { ApiError, functionError, must } from "./api";

export interface Money3 {
  coupons: string;
  redemption: string;
  total: string;
}

export interface NoteNext {
  kind: "observation" | "final";
  seq?: number;
  obs_date: string;
  pay_date: string;
  days: number;
  is_final: boolean;
  coupon?: { rate_pct: string; barrier_pct: string; amount: string; would_pay: boolean | null } | null;
  autocall?: { trigger_pct: string; redemption_pct: string; amount: string; would_call: boolean | null } | null;
}

export interface NoteSummary {
  note_code: string;
  holding_code: string;
  name: string;
  institution: string | null;
  product_name: string;
  isin: string | null;
  issuer: string | null;
  currency: string;
  status: string;
  awaiting_prices: boolean;
  trade_date: string;
  maturity_date: string;
  ended_on: string | null;
  invested: string;
  nominal: string;
  purchase_price_pct: string;
  funding_account_code: string | null;
  received: Money3;
  due: Money3;
  result: { total: string; profit: string; return_pct: string } | null;
  worst_now: { pct: string; symbol: string; priced: boolean } | null;
  break_even_pct: string | null;
  next: NoteNext | null;
  if_ended_today: { payout_pct: string; settlement: string; amount: string; total: string; profit: string } | null;
  /** What it fetches sold today at the broker's bid (20261027165732); null without a broker price. */
  market?: MarketQuote | null;
  /** The first autocall still ahead (20261027165732); null when none is left. */
  if_called_next?: CallScenario | null;
  symbols: string[];
  /** The note in one line (lib/note-verdict words it); absent on an older server. */
  verdict?: NoteVerdict | null;
}

export interface NoteUnderlying extends NoteShare {
  symbol: string;
  name: string;
  bloomberg_code: string | null;
  initial: string;
  close: string | null;
  close_date: string | null;
  perf_pct: string | null;
  is_worst: boolean;
  to_autocall_pct: string | null;
  to_coupon_pct: string | null;
  to_break_even_pct: string | null;
  autocall_level: string | null;
  coupon_level: string | null;
  break_even_level: string | null;
}

export interface NoteLevel {
  kind: "autocall" | "coupon" | "final" | "break_even";
  pct: string;
  date: string;
  distance_pct: string;
  payout_pct?: string;
  settlement?: string;
}

export type AutocallScenario = CallScenario;

export interface MaturityPoint {
  worst_pct: string;
  payout_pct: string;
  amount: string;
  settlement: string;
  profit: string;
}

/** Known kinds, plus any the server adds later (a new kind must never break the page: lib/notes outcomeLabel). */
export type OutcomeKind = "coupon" | "coupon_missed" | "autocall" | "autocall_missed" | "maturity" | "coupon_before_purchase" | (string & {});

export interface NoteOutcome {
  kind: OutcomeKind;
  seq: number | null;
  obs_date: string;
  pay_date: string;
  worst_pct: string;
  worst_symbol: string;
  barrier_pct?: string;
  trigger_pct?: string;
  rate_pct?: string;
  amount?: string;
  memory?: boolean;
  settlement?: string;
  shares?: string | null;
  share_value?: string | null;
  paid?: boolean;
}

export interface NoteObservation {
  seq: number;
  obs_date: string;
  pay_date: string;
  coupon_rate_pct: string | null;
  coupon_barrier_pct: string | null;
  coupon_memory: boolean;
  autocall_trigger_pct: string | null;
  autocall_amount_pct: string | null;
}

export interface NoteEvent {
  event_code: string;
  kind: OutcomeKind;
  obs_date: string;
  pay_date: string;
  rate_pct: string;
  amount: string;
  settlement: string;
  shares: string | null;
  share_symbol: string | null;
  txn_code: string | null;
  delivered_holding_code: string | null;
  settled: boolean;
}

export interface NoteDetail extends NoteSummary {
  terms: {
    guarantor: string | null;
    denomination: string;
    issue_price_pct: string;
    strike_date: string;
    issue_date: string | null;
    final_valuation_date: string;
    maturity_date: string;
    termsheet_path: string | null;
    termsheet_filename: string | null;
  };
  observations: NoteObservation[];
  payout: PayoutBranch[];
  memory_unpaid_pct: string;
  underlyings: NoteUnderlying[];
  levels: NoteLevel[] | null;
  scenarios: {
    autocall: AutocallScenario[];
    maturity: MaturityPoint[];
    remaining_coupons: string;
    best: { total: string; profit: string; when?: string; date?: string };
    worst: { total: string; profit: string };
  } | null;
  outcomes: NoteOutcome[];
  events: NoteEvent[];
  /** Each share's closes since the strike: [date, % of its initial level]. */
  series: Record<string, [string, string][]>;
}

export function useNotesSummary(profileCode: string) {
  return useQuery({
    queryKey: keys.notes(profileCode),
    queryFn: async () => {
      const args: RpcArgs<"structured_notes_summary"> = { p_profile_code: profileCode };
      return must(await supabase.rpc("structured_notes_summary", args)) as unknown as NoteSummary[];
    },
  });
}

export function useNoteDetail(profileCode: string, holdingCode: string, enabled = true) {
  return useQuery({
    queryKey: keys.noteDetail(profileCode, holdingCode),
    enabled,
    queryFn: async () => {
      const args: RpcArgs<"structured_note_detail"> = { p_profile_code: profileCode, p_holding_code: holdingCode };
      return must(await supabase.rpc("structured_note_detail", args)) as unknown as NoteDetail;
    },
  });
}

/**
 * A note's term sheet PDF from the private `term-sheets` bucket (storage RLS: members only), for
 * the in-app viewer and the share sheet. Fetched only while the viewer is open; the path is the
 * file's sha256, so a fetched copy never goes stale.
 */
export async function termSheetBlob(path: string): Promise<Blob> {
  const { data, error } = await supabase.storage.from("term-sheets").download(path);
  if (error || !data) {
    throw new ApiError(
      /not.?found/i.test(error?.message ?? "") ? "The PDF file isn't in storage." : (error?.message ?? "Couldn't open the PDF."),
    );
  }
  return data.type === "application/pdf" ? data : new Blob([data], { type: "application/pdf" });
}

export function useTermSheet(profileCode: string, path: string | null, enabled: boolean) {
  return useQuery({
    queryKey: keys.termSheet(profileCode, path ?? ""),
    enabled: enabled && !!path,
    staleTime: Infinity,
    gcTime: 60_000,
    retry: 1,
    queryFn: () => termSheetBlob(path!),
  });
}

/**
 * Every ledger domain that counts transactions refreshes: a note posts its purchase, coupons and
 * redemptions to the funding account, and an entry moves a balance.
 */
function invalidateLedger(qc: ReturnType<typeof useQueryClient>, profileCode: string) {
  return Promise.all(LEDGER_DOMAINS.map((d) => qc.invalidateQueries({ queryKey: keys.domain(profileCode, d) })));
}

/** stock-prices for this ledger: the closes its notes need, then settlement. */
export async function refreshNotePrices(profileCode: string): Promise<{ stored: number; failed: string[] }> {
  const { data, error } = await supabase.functions.invoke<{ stored: number; failed: string[] }>("stock-prices", {
    body: { profile_code: profileCode },
  });
  if (error) throw await functionError(error);
  return data ?? { stored: 0, failed: [] };
}

export function useRefreshNotePrices(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => refreshNotePrices(profileCode),
    onSettled: () => invalidateLedger(qc, profileCode),
  });
}

export function useCancelNote(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (holdingCode: string) => {
      const args: RpcArgs<"cancel_structured_note"> = { p_profile_code: profileCode, p_holding_code: holdingCode };
      must(await supabase.rpc("cancel_structured_note", args));
    },
    onSettled: () => invalidateLedger(qc, profileCode),
  });
}

export interface AccountEntryInput {
  account_code: string;
  direction: "credit" | "debit";
  amount: string;
  entry_date: string;
  description: string;
}

export function useAddAccountEntry(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (e: AccountEntryInput) => {
      const args: RpcArgs<"add_account_entry"> = {
        p_profile_code: profileCode,
        p_account_code: e.account_code,
        p_direction: e.direction,
        p_amount: e.amount,
        p_entry_date: e.entry_date,
      };
      if (e.description.trim()) args.p_description = e.description.trim();
      return must(await supabase.rpc("add_account_entry", args)) as string;
    },
    onSettled: () => invalidateLedger(qc, profileCode),
  });
}
