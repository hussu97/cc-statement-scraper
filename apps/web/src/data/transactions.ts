import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type Views } from "@/lib/supabase";
import { ilikePattern, UNCATEGORIZED, type ActivitySearch } from "@/lib/activity-filters";
import { DEFAULT_PAGE_SIZE, pageRange } from "@/lib/pagination";
import { keys, LEDGER_DOMAINS } from "./keys";
import { fetchPage, must, mustList } from "./api";

export type TxnRow = Views<"v_transactions">;

/** The subset of the PostgREST filter builder the activity filters use. */
export interface FilterBuilder<B> {
  eq(column: string, value: unknown): B;
  gte(column: string, value: unknown): B;
  lte(column: string, value: unknown): B;
  is(column: string, value: null | boolean): B;
  ilike(column: string, pattern: string): B;
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
  if (s.q) q = q.ilike("description", ilikePattern(s.q));
  return q;
}

export function useTransactions(profileCode: string, search: ActivitySearch) {
  return useQuery({
    queryKey: keys.transactions(profileCode, search),
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const size = search.size ?? DEFAULT_PAGE_SIZE;
      const { from, to } = pageRange(search.page ?? 1, size);
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
    },
  });
}

export function useTransaction(profileCode: string, txnCode: string | null) {
  return useQuery({
    queryKey: keys.transaction(profileCode, txnCode ?? ""),
    enabled: !!txnCode,
    queryFn: async () => must(await supabase.from("v_transactions").select("*").eq("txn_code", txnCode!).maybeSingle()),
  });
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
