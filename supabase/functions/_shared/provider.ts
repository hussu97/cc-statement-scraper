// Shared helpers for the mailbox providers (Gmail API, Microsoft Graph): the HTTP error
// type both clients throw, and a fast base64 decoder for attachment bodies.
//
// SRV-07: `Uint8Array.from(atob(s), c => c.charCodeAt(0))` costs about 1 s of CPU per
// 20 MB, against the 2 s Edge CPU limit. The native `Uint8Array.fromBase64` (V8 ≥ 14)
// takes ~4 ms and @std/encoding ~45 ms, so either is fine; the native one is used when
// the runtime has it.

import { decodeBase64, decodeBase64Url } from "./deps.ts";
import { MAX_PDF_BYTES } from "./documents.ts";

export class ProviderHttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "ProviderHttpError";
  }
}

type FromBase64 = (s: string, opts: { alphabet: "base64" | "base64url" }) => Uint8Array;
const nativeFromBase64: FromBase64 | null = typeof (Uint8Array as unknown as { fromBase64?: unknown }).fromBase64 ===
    "function"
  ? (Uint8Array as unknown as { fromBase64: FromBase64 }).fromBase64.bind(Uint8Array)
  : null;

/**
 * Decode standard or URL-safe base64, with or without padding (Gmail sends base64url
 * without padding, Graph standard base64). Whitespace is ignored. Throws on bad input.
 */
export function decodeBase64Any(data: string, impl: "auto" | "std" = "auto"): Uint8Array {
  const clean = data.replace(/\s+/g, "");
  if (!clean) return new Uint8Array();
  const urlSafe = /[-_]/.test(clean);
  if (impl === "auto" && nativeFromBase64) {
    // The default lastChunkHandling ("loose") accepts missing padding.
    return nativeFromBase64(clean, { alphabet: urlSafe ? "base64url" : "base64" });
  }
  return urlSafe ? decodeBase64Url(clean) : decodeBase64(clean);
}

/** Largest attachment worth downloading: the `statements` bucket and storeDocument limit. */
export const MAX_ATTACHMENT_BYTES = MAX_PDF_BYTES;

/**
 * True when a provider-reported attachment size is known and over the limit, so the
 * attachment is skipped before it is downloaded and decoded (SRV-07).
 */
export function attachmentTooLarge(size: unknown): boolean {
  const n = Number(size);
  return Number.isFinite(n) && n > MAX_ATTACHMENT_BYTES;
}
