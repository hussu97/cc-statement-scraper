import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type RpcReturn } from "@/lib/supabase";
import { keys, LEDGER_DOMAINS } from "./keys";
import { useInfiniteList } from "./infinite";
import { ApiError, fetchPage, functionError, must, mustList, toApiError, type Page } from "./api";
import { pageRange } from "@/lib/pagination";

export type StatementCycle = RpcReturn<"statement_cycles">[number];

export function useAccounts(profileCode: string) {
  return useQuery({
    queryKey: keys.accounts(profileCode),
    queryFn: async () =>
      mustList(
        await supabase
          .from("accounts")
          .select("*, cards(card_code, last4, holder_name, is_supplementary, status, wallet_name)")
          .eq("profile_code", profileCode)
          // Cards only: bank accounts (Phase 2a) have no card names, limits or statements.
          .eq("kind", "credit_card")
          .order("bank_code"),
      ),
  });
}

export function useUpdateAccount(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { accountCode: string; nickname: string | null; creditLimit: string | null }) =>
      must(
        await supabase
          .from("accounts")
          .update({
            nickname: v.nickname?.trim() || null,
            credit_limit: (v.creditLimit?.trim() || null) as unknown as number | null,
          })
          .eq("account_code", v.accountCode),
      ),
    onSettled: () =>
      Promise.all(
        (["accounts", "overview", "meta", "statements", "transactions"] as const).map((d) =>
          qc.invalidateQueries({ queryKey: ["p", profileCode, d] }),
        ),
      ),
  });
}

/** cards.wallet_name's CHECK: trimmed, 1–64 characters. */
export const WALLET_NAME_MAX = 64;

/**
 * A typed Wallet name as cards.wallet_name stores it: trimmed, internal
 * whitespace collapsed to one space, at most 64 characters; empty clears it
 * (null). Pure, unit-tested.
 */
export function normalizeWalletName(input: string | null | undefined): string | null {
  const s = (input ?? "").replace(/\s+/g, " ").trim().slice(0, WALLET_NAME_MAX).trim();
  return s || null;
}

/**
 * Friendly text for a cards.wallet_name update error. 23505: the per-ledger,
 * case-insensitive unique index (cards_wallet_name_uq). Pure, unit-tested.
 */
export function walletNameError(e: { code?: string; message?: string } | null | undefined): string {
  if (e?.code === "23505") return "Another card already uses this Wallet name.";
  if (e?.code === "23514") return `A Wallet name is 1 to ${WALLET_NAME_MAX} characters.`;
  return e?.message || "Something went wrong.";
}

/**
 * Set one card's Wallet name (the name the Wallet app shows for it; the payment
 * shortcut sends it). Setting it re-processes waiting Wallet payments and
 * resolves their unknown-card reviews server-side, so every ledger view is
 * refreshed afterwards.
 */
export function useUpdateCard(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { cardCode: string; walletName: string | null }) => {
      const res = await supabase
        .from("cards")
        .update({ wallet_name: normalizeWalletName(v.walletName) })
        .eq("card_code", v.cardCode)
        .eq("profile_code", profileCode)
        .select("card_code");
      if (res.error) throw new ApiError(walletNameError(res.error), { code: res.error.code, status: res.status });
      // RLS hides a card this caller can't change: no error, no row.
      if (!res.data?.length) throw new ApiError("You don't have permission to do that in this ledger.", { code: "42501" });
    },
    onSettled: () => Promise.all(LEDGER_DOMAINS.map((d) => qc.invalidateQueries({ queryKey: ["p", profileCode, d] }))),
  });
}

/** statement_cycles caps p_limit at 5000 server-side; the UI says so when it is reached. */
export const STATEMENT_CYCLES_MAX = 5000;

/** One page of statements, newest first, with the exact total (up to STATEMENT_CYCLES_MAX). */
/** Rows [from, to] of statement_cycles, newest first, with the exact total. */
export function fetchStatementCycles(profileCode: string, from: number, to: number): Promise<Page<StatementCycle>> {
  const args = { p_profile_code: profileCode, p_limit: STATEMENT_CYCLES_MAX };
  return fetchPage<StatementCycle>(
    () => supabase.rpc("statement_cycles", args, { count: "exact" }).range(from, to),
    () => supabase.rpc("statement_cycles", args, { count: "exact", head: true }),
  );
}

export function useStatementCycles(profileCode: string, page: number, size: number, enabled = true) {
  return useQuery({
    queryKey: [...keys.cycles(profileCode), page, size],
    enabled,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<Page<StatementCycle>> => {
      const { from, to } = pageRange(page, size);
      return fetchStatementCycles(profileCode, from, to);
    },
  });
}

const cycleId = (s: StatementCycle) => s.stmt_code;
/** Phones: every statement, a page of 100 at a time. */
export function useInfiniteStatementCycles(profileCode: string, enabled = true) {
  return useInfiniteList<StatementCycle>({
    queryKey: [...keys.cycles(profileCode), "infinite"],
    enabled,
    fetch: (from, to) => fetchStatementCycles(profileCode, from, to),
    idOf: cycleId,
  });
}

const DOC_COLUMNS =
  "doc_code, kind, bank_code, storage_path, original_filename, size_bytes, source, parse_status, parse_attempts, parser_version, parse_error_code, parse_error, parse_warnings, parsed_at, created_at, updated_at";

/** Rows [from, to] of documents, newest first, with the exact total. */
export function fetchDocuments(profileCode: string, from: number, to: number): Promise<Page<DocumentRow>> {
  const base = () => supabase.from("documents").select(DOC_COLUMNS, { count: "exact" }).eq("profile_code", profileCode);
  return fetchPage<DocumentRow>(
    () => base().order("created_at", { ascending: false }).order("doc_code", { ascending: false }).range(from, to),
    () => supabase.from("documents").select("doc_code", { count: "exact", head: true }).eq("profile_code", profileCode),
  );
}

/** One page of documents, newest first, with the exact total. */
export function useDocuments(profileCode: string, page: number, size: number, enabled = true) {
  return useQuery({
    queryKey: [...keys.documents(profileCode), "page", page, size],
    enabled,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const { from, to } = pageRange(page, size);
      return fetchDocuments(profileCode, from, to);
    },
  });
}

const docId = (d: DocumentRow) => d.doc_code;
/** Phones: every document, a page of 100 at a time. */
export function useInfiniteDocuments(profileCode: string, enabled = true) {
  return useInfiniteList<DocumentRow>({
    queryKey: [...keys.documents(profileCode), "infinite"],
    enabled,
    fetch: (from, to) => fetchDocuments(profileCode, from, to),
    idOf: docId,
  });
}

export interface DocumentRow {
  doc_code: string;
  kind: string;
  bank_code: string | null;
  storage_path: string;
  original_filename: string;
  size_bytes: number | null;
  source: string;
  parse_status: string;
  parse_attempts: number;
  parser_version: string | null;
  parse_error_code: string | null;
  parse_error: string | null;
  parse_warnings: unknown;
  parsed_at: string | null;
  created_at: string;
  updated_at: string;
}

/**
 * documents.parse_warnings (a jsonb array the parser and ingest fill) as short
 * display strings. Strings pass through; objects show their `message` or
 * `code`. Long digit runs (card or account numbers) are masked and each line is
 * capped, so a tooltip never shows more than the parser's own summary. Pure,
 * unit-tested.
 */
export function docWarnings(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const w of raw) {
    let text: string | null = null;
    if (typeof w === "string") text = w;
    else if (w && typeof w === "object") {
      const o = w as Record<string, unknown>;
      text = typeof o.message === "string" ? o.message : typeof o.code === "string" ? o.code : null;
    }
    if (!text?.trim()) continue;
    const masked = text.replace(/\d[\d ]{4,}\d/g, (m) => (m.replace(/\D/g, "").length >= 6 ? "••••" : m)).trim();
    out.push(masked.length > 160 ? `${masked.slice(0, 159)}…` : masked);
  }
  return out;
}

export const DOC_STATUSES = ["queued", "parsing", "parsed", "failed"] as const;

/**
 * Document counts by parse status (exact, server-side head counts) and the
 * codes of failed documents for "Retry failed". Never derived from a page.
 */
export function useDocumentHealth(profileCode: string) {
  return useQuery({
    queryKey: [...keys.documents(profileCode), "health"],
    queryFn: async () => {
      const head = (status: string) =>
        supabase.from("documents").select("doc_code", { count: "exact", head: true }).eq("profile_code", profileCode).eq("parse_status", status);
      const [counts, failed] = await Promise.all([
        Promise.all(DOC_STATUSES.map(async (st) => [st, (await head(st))] as const)),
        supabase.from("documents").select("doc_code").eq("profile_code", profileCode).eq("parse_status", "failed").order("created_at", { ascending: false }),
      ]);
      const out: Record<string, number> = {};
      for (const [st, res] of counts) {
        if (res.error) throw toApiError(res.error, res.status);
        out[st] = res.count ?? 0;
      }
      const failedCodes = mustList(failed).map((d) => d.doc_code);
      const total = Object.values(out).reduce((a, b) => a + b, 0);
      return { counts: out, total, failedCodes };
    },
  });
}

/** Storage path of one document, looked up on demand (never from a capped list). */
export async function documentStoragePath(docCode: string): Promise<string | null> {
  const row = must(await supabase.from("documents").select("storage_path").eq("doc_code", docCode).maybeSingle());
  return row?.storage_path ?? null;
}

export function useRequeueDocuments(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (docCodes: string[] | null) =>
      must(
        await supabase.rpc("requeue_documents", {
          p_profile_code: profileCode,
          ...(docCodes ? { p_doc_codes: docCodes } : {}),
        }),
      ) as number,
    onSettled: () => qc.invalidateQueries({ queryKey: keys.documents(profileCode) }),
  });
}

/** Short-lived signed URL for a stored PDF (storage RLS: members only). */
export async function signedDocumentUrl(storagePath: string): Promise<string> {
  const { data, error } = await supabase.storage.from("statements").createSignedUrl(storagePath, 120);
  if (error || !data?.signedUrl) {
    throw new ApiError(
      /not.?found/i.test(error?.message ?? "") ? "The PDF file isn't in storage." : (error?.message ?? "Couldn't open the PDF."),
    );
  }
  return data.signedUrl;
}

export interface UploadResult {
  filename: string;
  doc_code: string;
  status: "queued" | "duplicate";
}

export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

/** statements-upload accepts at most this many files per request (MAX_FILES in its form.ts). */
export const MAX_UPLOAD_FILES = 20;

/** Client-side pre-checks; the Edge Function validates again. Files past the 20th wait for the next upload (WEB-48). */
export function checkUploadFiles(files: File[]): { ok: File[]; rejected: { name: string; reason: string }[] } {
  const ok: File[] = [];
  const rejected: { name: string; reason: string }[] = [];
  for (const f of files) {
    if (!/\.pdf$/i.test(f.name) && f.type !== "application/pdf") rejected.push({ name: f.name, reason: "Not a PDF" });
    else if (f.size > MAX_UPLOAD_BYTES) rejected.push({ name: f.name, reason: "Larger than 25 MB" });
    else if (f.size === 0) rejected.push({ name: f.name, reason: "Empty file" });
    else if (ok.length >= MAX_UPLOAD_FILES) rejected.push({ name: f.name, reason: `Over ${MAX_UPLOAD_FILES} files; upload it next` });
    else ok.push(f);
  }
  return { ok, rejected };
}

export function useUploadStatements(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (files: File[]): Promise<UploadResult[]> => {
      const form = new FormData();
      form.append("profile_code", profileCode);
      for (const f of files) form.append("files", f, f.name);
      const { data, error } = await supabase.functions.invoke<{ uploads: UploadResult[] }>("statements-upload", {
        body: form,
      });
      if (error) throw await functionError(error);
      return data?.uploads ?? [];
    },
    onSettled: () => qc.invalidateQueries({ queryKey: keys.documents(profileCode) }),
  });
}
