// Storing an incoming statement PDF: validation, sha256 dedup, Storage upload and
// the `documents` row. Shared by statements-upload, gmail-push and outlook-poll.
// Each step is also written to the document's timeline (public.document_events:
// received, stored, queued, or duplicate), which the apps follow over Realtime.
//
// Ordering matters: the documents INSERT trigger enqueues `parse_document`, so the
// object must already be in Storage when the row appears. We therefore reserve a
// doc_code with gen_code('doc'), upload to <profile_code>/<doc_code>.pdf, then insert.
//
// Validation happens once, in prepareDocument (SRV-23); storeDocument only accepts a
// PreparedDocument, so nothing can be stored unvalidated.

import { HttpError, pgErrorToHttp } from "./http.ts";
import { captureMessage } from "./sentry.ts";
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

/** A validated, hashed PDF ready to store. */
export interface PreparedDocument {
  filename: string;
  bytes: Uint8Array;
  sha256: string;
}

/** Sanitise the name, validate the bytes (413/422 HttpErrors) and hash them. */
export async function prepareDocument(
  bytes: Uint8Array,
  name: string | null | undefined,
): Promise<PreparedDocument> {
  const filename = sanitizeFilename(name);
  validatePdf(bytes, filename);
  return { filename, bytes, sha256: await sha256Hex(bytes) };
}

export interface StoreInput {
  profileCode: string;
  document: PreparedDocument;
  source: DocumentSource;
  sourceRef?: string | null;
  bankCodeHint?: string | null;
}

export type ParseStatus = "queued" | "parsing" | "parsed" | "failed";

export interface StoreResult {
  status: "queued" | "duplicate";
  doc_code: string;
  sha256: string;
  /** The document's parse status after this call (a requeued duplicate is `queued`). */
  parse_status: ParseStatus;
  /** True when a duplicate of a failed document was queued for parsing again (SRV-20). */
  requeued?: boolean;
}

interface ExistingDoc {
  doc_code: string;
  parse_status: ParseStatus;
}

async function findBySha(svc: Db, profileCode: string, sha: string): Promise<ExistingDoc | null> {
  const { data, error } = await svc
    .from("documents")
    .select("doc_code, parse_status")
    .eq("profile_code", profileCode)
    .eq("sha256", sha)
    .maybeSingle();
  if (error) throw pgErrorToHttp(error, "document lookup failed");
  return data ? { doc_code: String(data.doc_code), parse_status: data.parse_status as ParseStatus } : null;
}

/**
 * SRV-20: re-sending a PDF whose parse failed (for example before its password was set)
 * queues it again (`resubmit_document`) instead of answering a bare `duplicate`. A
 * failed resubmit is reported, not thrown: the upload itself succeeded, and the owner
 * can still requeue by hand.
 */
async function duplicateResult(svc: Db, profileCode: string, doc: ExistingDoc, sha: string): Promise<StoreResult> {
  const base: StoreResult = {
    status: "duplicate",
    doc_code: doc.doc_code,
    sha256: sha,
    parse_status: doc.parse_status,
  };
  if (doc.parse_status !== "failed") return base;
  const { data, error } = await svc.rpc("resubmit_document", {
    p_profile_code: profileCode,
    p_doc_code: doc.doc_code,
  });
  const r = (data ?? {}) as { parse_status?: unknown; requeued?: unknown };
  if (error || typeof r.parse_status !== "string") {
    captureMessage("could not resubmit a re-sent failed document", {
      level: "warning",
      tags: { profile_code: profileCode, doc_code: doc.doc_code, sqlstate: error?.code },
      fingerprint: ["documents", "resubmit_failed_duplicate"],
    });
    return base;
  }
  return { ...base, parse_status: r.parse_status as ParseStatus, ...(r.requeued === true ? { requeued: true } : {}) };
}

// ── document timeline (public.document_events) ──────────────────────────────

export type DocumentStage =
  | "received"
  | "stored"
  | "duplicate"
  | "queued"
  | "parsing"
  | "parsed"
  | "ingested"
  | "failed"
  | "retry";

export interface DocumentEvent {
  stage: DocumentStage;
  level: "info" | "warn" | "error";
  /** A sentence for end users: never a password, PDF text, line text or SMS body. */
  message: string;
  detail: Record<string, unknown>;
}

/** "812 B", "48 KB", "1.2 MB". */
export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return "0 B";
  if (n < 1024) return `${Math.round(n)} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

/** The upload-side events storeDocument writes (pure, for tests). */
export const uploadEvents = {
  received: (filename: string, sizeBytes: number, source: DocumentSource): DocumentEvent => ({
    stage: "received",
    level: "info",
    message: `Received ${filename} (${formatBytes(sizeBytes)}).`,
    detail: { filename, size_bytes: sizeBytes, source },
  }),
  stored: (): DocumentEvent => ({ stage: "stored", level: "info", message: "Saved the PDF.", detail: {} }),
  queued: (): DocumentEvent => ({ stage: "queued", level: "info", message: "Waiting to be read.", detail: {} }),
  duplicate: (filename: string, parseStatus: ParseStatus): DocumentEvent => ({
    stage: "duplicate",
    level: "info",
    message: parseStatus === "failed"
      ? `${filename} was uploaded before and could not be read then.`
      : `${filename} was uploaded before; there is nothing new to import.`,
    detail: { filename, parse_status: parseStatus },
  }),
};

/**
 * Append an event to a document's timeline with the service-role RPC log_document_event.
 * Never throws: a lost timeline entry must not fail an upload or a parse.
 */
export async function logDocumentEvent(
  svc: Db,
  profileCode: string,
  docCode: string,
  event: DocumentEvent,
): Promise<void> {
  try {
    const { error } = await svc.rpc("log_document_event", {
      p_profile_code: profileCode,
      p_doc_code: docCode,
      p_stage: event.stage,
      p_level: event.level,
      p_message: event.message,
      p_detail: event.detail,
    });
    if (error) {
      captureMessage("could not log a document event", {
        level: "warning",
        tags: { profile_code: profileCode, doc_code: docCode, stage: event.stage, sqlstate: error.code },
        fingerprint: ["documents", "log_document_event_failed"],
      });
    }
  } catch {
    // best effort
  }
}

/** Dedupe and store one prepared PDF. Uses the service-role client (caller already authorised). */
export async function storeDocument(svc: Db, input: StoreInput): Promise<StoreResult> {
  const { filename, bytes, sha256: sha } = input.document;
  const received = uploadEvents.received(filename, bytes.length, input.source);

  const existing = await findBySha(svc, input.profileCode, sha);
  if (existing) {
    await logDocumentEvent(svc, input.profileCode, existing.doc_code, received);
    await logDocumentEvent(
      svc,
      input.profileCode,
      existing.doc_code,
      uploadEvents.duplicate(filename, existing.parse_status),
    );
    return await duplicateResult(svc, input.profileCode, existing, sha);
  }

  const { data: docCode, error: codeErr } = await svc.rpc("gen_code", { prefix: "doc" });
  if (codeErr || typeof docCode !== "string") throw pgErrorToHttp(codeErr, "could not allocate doc_code");
  const path = `${input.profileCode}/${docCode}.pdf`;
  await logDocumentEvent(svc, input.profileCode, docCode, received);

  const bucket = svc.storage.from("statements");
  const up = await bucket.upload(path, bytes, { contentType: "application/pdf", upsert: false });
  if (up.error) throw new HttpError(502, "STORAGE_UPLOAD_FAILED", "could not store the PDF");
  await logDocumentEvent(svc, input.profileCode, docCode, uploadEvents.stored());

  const { error: insErr } = await svc.from("documents").insert({
    doc_code: docCode,
    profile_code: input.profileCode,
    bank_code: input.bankCodeHint ?? null,
    storage_path: path,
    original_filename: filename,
    sha256: sha,
    size_bytes: bytes.length,
    source: input.source,
    source_ref: input.sourceRef ?? null,
  });
  if (insErr) {
    await bucket.remove([path]).catch(() => undefined);
    if (insErr.code === "23505") {
      // Lost a race with a concurrent upload of the same file.
      const winner = await findBySha(svc, input.profileCode, sha);
      if (winner) {
        await logDocumentEvent(
          svc,
          input.profileCode,
          winner.doc_code,
          uploadEvents.duplicate(filename, winner.parse_status),
        );
        return await duplicateResult(svc, input.profileCode, winner, sha);
      }
    }
    throw pgErrorToHttp(insErr, "could not record the document");
  }
  await logDocumentEvent(svc, input.profileCode, docCode, uploadEvents.queued());
  return { status: "queued", doc_code: docCode, sha256: sha, parse_status: "queued" };
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
