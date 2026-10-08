// Storing an incoming statement PDF: validation, sha256 dedup, Storage upload and
// the `documents` row. Shared by statements-upload, gmail-push and outlook-poll.
//
// Ordering matters: the documents INSERT trigger enqueues `parse_document`, so the
// object must already be in Storage when the row appears. We therefore reserve a
// doc_code with gen_code('doc'), upload to <profile_code>/<doc_code>.pdf, then insert.

import { HttpError, pgErrorToHttp } from "./http.ts";
import type { Db } from "./supabase.ts";

export const MAX_PDF_BYTES = 25 * 1024 * 1024; // matches the `statements` bucket limit
export const DOCUMENT_SOURCES = ["scraper", "upload", "ios", "gmail", "outlook", "legacy"] as const;
export type DocumentSource = (typeof DOCUMENT_SOURCES)[number];

/** `%PDF-` must appear in the first 1024 bytes (the PDF spec allows leading junk). */
export function isPdf(bytes: Uint8Array): boolean {
  const n = Math.min(bytes.length, 1024);
  for (let i = 0; i + 4 < n; i++) {
    if (
      bytes[i] === 0x25 && bytes[i + 1] === 0x50 && bytes[i + 2] === 0x44 && bytes[i + 3] === 0x46 &&
      bytes[i + 4] === 0x2d
    ) {
      return true;
    }
  }
  return false;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Basename only, control characters stripped, at most 200 chars. */
export function sanitizeFilename(name: string | null | undefined): string {
  const base = String(name ?? "").split(/[\\/]/).pop() ?? "";
  // deno-lint-ignore no-control-regex
  const clean = base.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(-200);
  return clean || "statement.pdf";
}

/** Throws 413/422 HttpErrors for unacceptable files. */
export function validatePdf(bytes: Uint8Array, filename: string): void {
  if (bytes.length === 0) throw new HttpError(422, "EMPTY_FILE", `${filename} is empty`);
  if (bytes.length > MAX_PDF_BYTES) {
    throw new HttpError(413, "FILE_TOO_LARGE", `${filename} exceeds the ${MAX_PDF_BYTES / 1024 / 1024} MB limit`);
  }
  if (!isPdf(bytes)) throw new HttpError(422, "NOT_A_PDF", `${filename} is not a PDF`);
}

export interface StoreInput {
  profileCode: string;
  bytes: Uint8Array;
  filename: string;
  source: DocumentSource;
  sourceRef?: string | null;
  bankCodeHint?: string | null;
}

export interface StoreResult {
  status: "queued" | "duplicate";
  doc_code: string;
  sha256: string;
}

async function findBySha(svc: Db, profileCode: string, sha: string): Promise<string | null> {
  const { data, error } = await svc
    .from("documents")
    .select("doc_code")
    .eq("profile_code", profileCode)
    .eq("sha256", sha)
    .maybeSingle();
  if (error) throw pgErrorToHttp(error, "document lookup failed");
  return data?.doc_code ?? null;
}

/** Validate, dedupe and store one PDF. Uses the service-role client (caller already authorised). */
export async function storeDocument(svc: Db, input: StoreInput): Promise<StoreResult> {
  const filename = sanitizeFilename(input.filename);
  validatePdf(input.bytes, filename);
  const sha = await sha256Hex(input.bytes);

  const existing = await findBySha(svc, input.profileCode, sha);
  if (existing) return { status: "duplicate", doc_code: existing, sha256: sha };

  const { data: docCode, error: codeErr } = await svc.rpc("gen_code", { prefix: "doc" });
  if (codeErr || typeof docCode !== "string") throw pgErrorToHttp(codeErr, "could not allocate doc_code");
  const path = `${input.profileCode}/${docCode}.pdf`;

  const bucket = svc.storage.from("statements");
  const up = await bucket.upload(path, input.bytes, { contentType: "application/pdf", upsert: false });
  if (up.error) throw new HttpError(502, "STORAGE_UPLOAD_FAILED", "could not store the PDF");

  const { error: insErr } = await svc.from("documents").insert({
    doc_code: docCode,
    profile_code: input.profileCode,
    bank_code: input.bankCodeHint ?? null,
    storage_path: path,
    original_filename: filename,
    sha256: sha,
    size_bytes: input.bytes.length,
    source: input.source,
    source_ref: input.sourceRef ?? null,
  });
  if (insErr) {
    await bucket.remove([path]).catch(() => undefined);
    if (insErr.code === "23505") {
      // Lost a race with a concurrent upload of the same file.
      const winner = await findBySha(svc, input.profileCode, sha);
      if (winner) return { status: "duplicate", doc_code: winner, sha256: sha };
    }
    throw pgErrorToHttp(insErr, "could not record the document");
  }
  return { status: "queued", doc_code: docCode, sha256: sha };
}

/** Normalise a bank hint and check it exists in `banks`. Returns null for empty hints. */
export async function validateBankHint(svc: Db, hint: string | null | undefined): Promise<string | null> {
  const code = (hint ?? "").trim().toUpperCase();
  if (!code) return null;
  if (!/^[A-Z]{2,10}$/.test(code)) throw new HttpError(422, "INVALID_BANK", "bank_code_hint is not a bank code");
  const { data, error } = await svc.from("banks").select("bank_code").eq("bank_code", code).maybeSingle();
  if (error) throw pgErrorToHttp(error, "bank lookup failed");
  if (!data) throw new HttpError(422, "INVALID_BANK", `unknown bank ${code}`);
  return code;
}
