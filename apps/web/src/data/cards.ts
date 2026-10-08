import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FunctionsHttpError } from "@supabase/supabase-js";
import { supabase, type RpcReturn } from "@/lib/supabase";
import { keys } from "./keys";
import { ApiError, fetchPage, must, mustList, toApiError, type Page } from "./api";
import { pageRange } from "@/lib/pagination";

export type StatementCycle = RpcReturn<"statement_cycles">[number];

export function useAccounts(profileCode: string) {
  return useQuery({
    queryKey: keys.accounts(profileCode),
    queryFn: async () =>
      mustList(
        await supabase
          .from("accounts")
          .select("*, cards(card_code, last4, holder_name, is_supplementary, status)")
          .eq("profile_code", profileCode)
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

/** statement_cycles caps p_limit at 500 server-side; the UI says so when it is reached. */
export const STATEMENT_CYCLES_MAX = 500;

/** One page of statements, newest first, with the exact total (up to STATEMENT_CYCLES_MAX). */
export function useStatementCycles(profileCode: string, page: number, size: number) {
  return useQuery({
    queryKey: [...keys.cycles(profileCode), page, size],
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<Page<StatementCycle>> => {
      const { from, to } = pageRange(page, size);
      const args = { p_profile_code: profileCode, p_limit: STATEMENT_CYCLES_MAX };
      return fetchPage<StatementCycle>(
        () => supabase.rpc("statement_cycles", args, { count: "exact" }).range(from, to),
        () => supabase.rpc("statement_cycles", args, { count: "exact", head: true }),
      );
    },
  });
}

const DOC_COLUMNS =
  "doc_code, kind, bank_code, storage_path, original_filename, size_bytes, source, parse_status, parse_attempts, parser_version, parse_error_code, parse_error, parse_warnings, parsed_at, created_at, updated_at";

/** One page of documents, newest first, with the exact total. */
export function useDocuments(profileCode: string, page: number, size: number) {
  return useQuery({
    queryKey: [...keys.documents(profileCode), "page", page, size],
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const { from, to } = pageRange(page, size);
      const base = () => supabase.from("documents").select(DOC_COLUMNS, { count: "exact" }).eq("profile_code", profileCode);
      return fetchPage<DocumentRow>(
        () => base().order("created_at", { ascending: false }).order("doc_code", { ascending: false }).range(from, to),
        () => supabase.from("documents").select("doc_code", { count: "exact", head: true }).eq("profile_code", profileCode),
      );
    },
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

/** Client-side pre-checks; the Edge Function validates again. */
export function checkUploadFiles(files: File[]): { ok: File[]; rejected: { name: string; reason: string }[] } {
  const ok: File[] = [];
  const rejected: { name: string; reason: string }[] = [];
  for (const f of files) {
    if (!/\.pdf$/i.test(f.name) && f.type !== "application/pdf") rejected.push({ name: f.name, reason: "Not a PDF" });
    else if (f.size > MAX_UPLOAD_BYTES) rejected.push({ name: f.name, reason: "Larger than 25 MB" });
    else if (f.size === 0) rejected.push({ name: f.name, reason: "Empty file" });
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
      if (error) {
        let message = error.message;
        if (error instanceof FunctionsHttpError) {
          try {
            const body = (await error.context.json()) as { error?: { message?: string; code?: string } };
            message = body.error?.message ?? message;
          } catch {
            /* keep generic message */
          }
        }
        throw new ApiError(message);
      }
      return data?.uploads ?? [];
    },
    onSettled: () => qc.invalidateQueries({ queryKey: keys.documents(profileCode) }),
  });
}
