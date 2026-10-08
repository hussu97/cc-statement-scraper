import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FunctionsHttpError } from "@supabase/supabase-js";
import { supabase, type RpcReturn } from "@/lib/supabase";
import { keys } from "./keys";
import { ApiError, must, mustList } from "./api";

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

export function useStatementCycles(profileCode: string, limit = 120) {
  return useQuery({
    queryKey: keys.cycles(profileCode),
    queryFn: async () => mustList(await supabase.rpc("statement_cycles", { p_profile_code: profileCode, p_limit: limit })),
  });
}

export function useDocuments(profileCode: string) {
  return useQuery({
    queryKey: keys.documents(profileCode),
    queryFn: async () =>
      mustList(
        await supabase
          .from("documents")
          .select(
            "doc_code, kind, bank_code, storage_path, original_filename, size_bytes, source, parse_status, parse_attempts, parser_version, parse_error_code, parse_error, parse_warnings, parsed_at, created_at, updated_at",
          )
          .eq("profile_code", profileCode)
          .order("created_at", { ascending: false })
          .limit(500),
      ),
  });
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

/** Counts by parse status for the health panel. */
export function countByStatus<T extends { parse_status: string }>(docs: T[]): Record<string, number> {
  const out: Record<string, number> = { queued: 0, parsing: 0, parsed: 0, failed: 0 };
  for (const d of docs) out[d.parse_status] = (out[d.parse_status] ?? 0) + 1;
  return out;
}
