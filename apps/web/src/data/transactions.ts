import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type Views, type RpcArgs } from "@/lib/supabase";
import { searchOrFilter, UNCATEGORIZED, type ActivitySearch } from "@/lib/activity-filters";
import type { ISODate } from "@/lib/dates";
import { DEFAULT_PAGE_SIZE, pageRange } from "@/lib/pagination";
import { keys, LEDGER_DOMAINS } from "./keys";
import { fetchPage, must, mustList, type Page } from "./api";
import { useInfiniteList } from "./infinite";

export type TxnRow = Views<"v_transactions">;

/** The subset of the PostgREST filter builder the activity filters use. */
export interface FilterBuilder<B> {
  eq(column: string, value: unknown): B;
  gte(column: string, value: unknown): B;
  lte(column: string, value: unknown): B;
  is(column: string, value: null | boolean): B;
  or(filters: string): B;
}

/** Apply URL filters to a v_transactions query. Pure: unit-tested with a fake builder. */
export function applyActivityFilters<B extends FilterBuilder<B>>(query: B, s: ActivitySearch): B {
  let q = query;
  if (s.from) q = q.gte("txn_date", s.from);
  if (s.to) q = q.lte("txn_date", s.to);
  if (s.account) q = q.eq("account_code", s.account);
  if (s.card) q = q.eq("card_code", s.card);
  if (s.category === UNCATEGORIZED) q = q.is("category_code", null);
  else if (s.category) q = q.eq("category_code", s.category);
  if (s.status) q = q.eq("status", s.status);
  if (s.source === "sms") q = q.eq("has_sms", true).eq("has_statement", false);
  if (s.source === "statement") q = q.eq("has_statement", true).eq("has_sms", false);
  if (s.source === "both") q = q.eq("has_sms", true).eq("has_statement", true);
  // Description OR merchant name, cleaned as iOS and activity_summary clean it.
  const search = searchOrFilter(s.q);
  if (search) q = q.or(search);
  return q;
}

/** The Activity header's numbers for the current filters (public.activity_summary). */
export interface ActivitySummary {
  txn_count: number;
  /** Debits minus credits in AED, void excluded: a decimal string. */
  net_aed: string;
  /** Matching non-void rows with no AED amount yet (left out of net_aed). */
  unpriced_count: number;
  /** Some AED amounts use an estimated FX rate. */
  has_estimate: boolean;
  earliest_date: ISODate | null;
  latest_date: ISODate | null;
}

/** ActivitySearch -> activity_summary args (paging and the drawer are ignored). Pure. */
export function activitySummaryArgs(profileCode: string, s: ActivitySearch): RpcArgs<"activity_summary"> {
  const args: RpcArgs<"activity_summary"> = { p_profile_code: profileCode };
  if (s.from) args.p_from = s.from;
  if (s.to) args.p_to = s.to;
  if (s.account) args.p_account_code = s.account;
  if (s.card) args.p_card_code = s.card;
  if (s.category === UNCATEGORIZED) args.p_uncategorized = true;
  else if (s.category) args.p_category_code = s.category;
  if (s.status) args.p_status = s.status;
  if (s.source) args.p_source = s.source;
  if (s.q?.trim()) args.p_q = s.q;
  return args;
}

/** Count, net AED and date span of every transaction matching the Activity filters. */
export function useActivitySummary(profileCode: string, search: ActivitySearch) {
  const filters = listFilters(search);
  return useQuery({
    queryKey: keys.activitySummary(profileCode, filters),
    placeholderData: keepPreviousData,
    queryFn: async () => must(await supabase.rpc("activity_summary", activitySummaryArgs(profileCode, filters))) as unknown as ActivitySummary,
  });
}

/** Rows [from, to] of v_transactions for the filters, newest first, with the exact total. */
export function fetchTransactions(profileCode: string, search: ActivitySearch, from: number, to: number): Promise<Page<TxnRow>> {
  // An out-of-range page returns { rows: [], total } and the screen clamps (WEB-01).
  return fetchPage<TxnRow>(
    () =>
      applyActivityFilters(supabase.from("v_transactions").select("*", { count: "exact" }).eq("profile_code", profileCode), search)
        .order("txn_date", { ascending: false })
        .order("txn_at", { ascending: false, nullsFirst: false })
        .order("txn_code", { ascending: false })
        .range(from, to),
    () => applyActivityFilters(supabase.from("v_transactions").select("txn_code", { count: "exact", head: true }).eq("profile_code", profileCode), search),
  );
}

/** One numbered page (desktop, and any caller that wants a fixed page). */
export function useTransactions(profileCode: string, search: ActivitySearch, enabled = true) {
  return useQuery({
    queryKey: keys.transactions(profileCode, search),
    enabled,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const size = search.size ?? DEFAULT_PAGE_SIZE;
      const { from, to } = pageRange(search.page ?? 1, size);
      return fetchTransactions(profileCode, search, from, to);
    },
  });
}

/** The filters that define a list, without paging (an infinite list's identity). Pure. */
export function listFilters(search: ActivitySearch): ActivitySearch {
  const { page: _page, size: _size, txn: _txn, ...filters } = search;
  return filters;
}

const txnId = (t: TxnRow) => t.txn_code;
/** Phones: every matching transaction, 100 at a time; a filter change starts again from the top. */
export function useInfiniteTransactions(profileCode: string, search: ActivitySearch, enabled = true) {
  const filters = listFilters(search);
  return useInfiniteList<TxnRow>({
    queryKey: [...keys.domain(profileCode, "transactions"), "infinite", filters],
    enabled,
    fetch: (from, to) => fetchTransactions(profileCode, filters, from, to),
    idOf: txnId,
  });
}

/** One transaction of the active ledger; null when it isn't in this ledger (WEB-46). */
export function useTransaction(profileCode: string, txnCode: string | null) {
  return useQuery({
    queryKey: keys.transaction(profileCode, txnCode ?? ""),
    enabled: !!txnCode,
    queryFn: async () => must(await supabase.from("v_transactions").select("*").eq("profile_code", profileCode).eq("txn_code", txnCode!).maybeSingle()),
  });
}

/**
 * The ledger a transaction outside the active one belongs to, among the
 * ledgers the caller can see (RLS); null when it is in none of them. Asked
 * only after useTransaction comes back empty (WEB-46).
 */
export function useTransactionLedger(profileCode: string, txnCode: string | null, enabled: boolean) {
  return useQuery({
    queryKey: [...keys.transaction(profileCode, txnCode ?? ""), "ledger"],
    enabled: enabled && !!txnCode,
    queryFn: async () => {
      const row = must(await supabase.from("v_transactions").select("profile_code").eq("txn_code", txnCode!).maybeSingle());
      return row?.profile_code ?? null;
    },
  });
}

/**
 * The ledger to offer for a txn= that isn't in the active one: the owning
 * ledger when it is in the caller's switcher list, else null ("not found"). Pure.
 */
export function elsewhereLedger<P extends { profile_code: string }>(ownerCode: string | null | undefined, activeCode: string, profiles: P[]): P | null {
  if (!ownerCode || ownerCode === activeCode) return null;
  return profiles.find((p) => p.profile_code === ownerCode) ?? null;
}

export interface EvidenceItem {
  evidence_code: string;
  evidence_type: "statement_line" | "history_line" | "sms";
  role: string;
  method: string;
  score: number | null;
  is_active: boolean;
  is_locked: boolean;
  created_at: string;
  deactivated_at: string | null;
  statement_lines: {
    line_code: string;
    stmt_code: string;
    txn_date: string;
    posting_date: string | null;
    description_raw: string;
    amount_original: number;
    currency_original: string;
    amount_aed: number | null;
    fx_rate: number | null;
    card_last4: string | null;
    statements: { statement_date: string; kind: string } | null;
  } | null;
  sms_messages: {
    sms_code: string;
    received_at: string;
    event_at: string | null;
    sender: string;
    msg_kind: string | null;
    amount: number | null;
    currency: string | null;
    card_last4: string | null;
    available_limit: number | null;
  } | null;
}

export function useEvidence(profileCode: string, txnCode: string | null) {
  return useQuery({
    queryKey: keys.evidence(profileCode, txnCode ?? ""),
    enabled: !!txnCode,
    queryFn: async () => {
      const rows = mustList(
        await supabase
          .from("transaction_evidence")
          .select(
            "evidence_code, evidence_type, role, method, score, is_active, is_locked, created_at, deactivated_at," +
              " statement_lines(line_code, stmt_code, txn_date, posting_date, description_raw, amount_original, currency_original, amount_aed, fx_rate, card_last4, statements(statement_date, kind))," +
              " sms_messages(sms_code, received_at, event_at, sender, msg_kind, amount, currency, card_last4, available_limit)",
          )
          .eq("txn_code", txnCode!),
      ) as unknown as EvidenceItem[];
      return sortEvidence(rows);
    },
  });
}

/** Timeline order: when the evidence happened (SMS time / statement date). */
export function evidenceTime(e: EvidenceItem): string {
  if (e.sms_messages) return e.sms_messages.event_at ?? e.sms_messages.received_at;
  if (e.statement_lines) return e.statement_lines.posting_date ?? e.statement_lines.txn_date;
  return e.created_at;
}

export function sortEvidence(list: EvidenceItem[]): EvidenceItem[] {
  return [...list].sort((a, b) => Number(b.is_active) - Number(a.is_active) || evidenceTime(a).localeCompare(evidenceTime(b)));
}

/** Fetched only when the person expands an SMS: bodies are never preloaded. */
export function useSmsBody(profileCode: string, smsCode: string | null) {
  return useQuery({
    queryKey: keys.smsBody(profileCode, smsCode ?? ""),
    enabled: !!smsCode,
    staleTime: 0,
    gcTime: 0,
    queryFn: async (): Promise<string | null> => {
      const res = await supabase.from("sms_messages").select("body").eq("sms_code", smsCode!).single();
      if (res.error) must(res);
      return res.data?.body ?? null;
    },
  });
}

/** The reversal pair of a transaction, in either direction. */
export function useRelatedTransactions(profileCode: string, txn: TxnRow | null | undefined) {
  return useQuery({
    queryKey: [...keys.transaction(profileCode, txn?.txn_code ?? ""), "related"],
    enabled: !!txn?.txn_code,
    queryFn: async () => {
      const filters = [`related_txn_code.eq.${txn!.txn_code}`];
      if (txn!.related_txn_code) filters.push(`txn_code.eq.${txn!.related_txn_code}`);
      return mustList(await supabase.from("v_transactions").select("*").or(filters.join(",")).limit(10));
    },
  });
}

function useInvalidateLedger(profileCode: string) {
  const qc = useQueryClient();
  return () => Promise.all(LEDGER_DOMAINS.map((d) => qc.invalidateQueries({ queryKey: ["p", profileCode, d] })));
}

export function useSetCategory(profileCode: string) {
  const invalidate = useInvalidateLedger(profileCode);
  return useMutation({
    mutationFn: async (v: { txnCode: string; categoryCode: string | null; applyToMerchant: boolean }) =>
      must(
        await supabase.rpc("set_transaction_category", {
          p_txn_code: v.txnCode,
          // Clearing a manual choice is null; the generated type marks it required.
          p_category_code: v.categoryCode as string,
          p_apply_to_merchant: v.applyToMerchant,
        }),
      ),
    onSettled: invalidate,
  });
}

export function useBulkSetCategory(profileCode: string) {
  const invalidate = useInvalidateLedger(profileCode);
  return useMutation({
    mutationFn: async (v: { txnCodes: string[]; categoryCode: string | null }) =>
      must(
        await supabase.rpc("set_transactions_category", {
          p_txn_codes: v.txnCodes,
          p_category_code: v.categoryCode as string,
        }),
      ) as number,
    onSettled: invalidate,
  });
}

export function useUpdateTransaction(profileCode: string) {
  const invalidate = useInvalidateLedger(profileCode);
  return useMutation({
    mutationFn: async (v: { txnCode: string; patch: { notes?: string | null; exclude_from_spend?: boolean } }) =>
      must(await supabase.from("transactions").update(v.patch).eq("txn_code", v.txnCode)),
    onSettled: invalidate,
  });
}

/** Badge for where a transaction's evidence came from. */
export function evidenceBadge(t: Pick<TxnRow, "has_sms" | "has_statement" | "status">):
  | "both"
  | "sms"
  | "statement"
  | "orphaned"
  | "none" {
  if (t.status === "orphaned") return "orphaned";
  if (t.has_sms && t.has_statement) return "both";
  if (t.has_sms) return "sms";
  if (t.has_statement) return "statement";
  return "none";
}

/** Consecutive rows grouped by txn_date, preserving server order. */
export function groupByDay<T extends { txn_date: string | null }>(rows: T[]): { day: string; rows: T[] }[] {
  const out: { day: string; rows: T[] }[] = [];
  for (const r of rows) {
    const day = r.txn_date ?? "";
    const last = out[out.length - 1];
    if (last && last.day === day) last.rows.push(r);
    else out.push({ day, rows: [r] });
  }
  return out;
}

export const EVIDENCE_LABEL: Record<string, string> = {
  statement_line: "Statement line",
  history_line: "History export line",
  sms: "Bank SMS",
};

export const ROLE_LABEL: Record<string, string> = {
  primary: "created the transaction",
  auth: "authorisation",
  post: "posted",
  reversal: "reversal",
  duplicate: "duplicate alert",
};

export const METHOD_LABEL: Record<string, string> = {
  new: "new",
  exact: "exact match",
  scored: "scored match",
  tie: "identical twin",
  manual: "linked by you",
  legacy: "imported",
};
