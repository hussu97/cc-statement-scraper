// parse_document queue consumer: signed URL → parser /parse → ingest_parsed_document.

import { captureMessage, traceHeaders } from "../_shared/sentry.ts";
import type { Db } from "../_shared/supabase.ts";
import { attemptOf, MAX_READS, type QueueMessage, queueDelete, retryLater, toDlq } from "./queue.ts";

export const PARSE_QUEUE = "parse_document";

/**
 * Parser error codes that mean "this document can never be parsed as it is" (contract
 * parse-v1, 422). Only a 422 whose body carries one of these is permanent; every other
 * non-2xx (404/403 from a wrong PARSER_URL or IAM, 400/413 from a proxy, 5xx, timeouts)
 * is retried and then dead-lettered, so a misconfiguration never fails documents for good.
 */
export const PERMANENT_PARSER_CODES: ReadonlySet<string> = new Set([
  "PDF_DECRYPT_FAILED",
  "UNSUPPORTED_BANK",
  "UNSUPPORTED_LAYOUT",
  "BANK_UNDETECTED",
  "DOWNLOAD_FAILED",
  "INVALID_REQUEST",
  "PARSE_TIMEOUT",
  "PDF_TOO_LARGE",
  "PARSE_OUTPUT_INVALID",
]);

export type ParserOutcome =
  | { action: "ingest"; payload: Record<string, unknown> }
  | { action: "permanent"; code: string; message: string; status: number }
  | { action: "transient"; code: string; message: string; status: number; config: boolean };

function contractError(body: unknown): { code: string; message: string } | null {
  if (!body || typeof body !== "object") return null;
  const err = (body as { error?: unknown }).error;
  if (!err || typeof err !== "object") return null;
  const { code, message } = err as { code?: unknown; message?: unknown };
  if (typeof code !== "string" || !/^[A-Z][A-Z0-9_]{1,63}$/.test(code)) return null;
  return { code, message: typeof message === "string" ? message.slice(0, 500) : "" };
}

/** Decide what to do with a parser HTTP response (contract parse-v1, "Response 4xx/5xx"). */
export function classifyParserResponse(status: number, body: unknown): ParserOutcome {
  if (status === 200) {
    if (body && typeof body === "object" && (body as { contract_version?: unknown }).contract_version === 1) {
      return { action: "ingest", payload: body as Record<string, unknown> };
    }
    // A 200 that isn't parse-v1: wrong service behind PARSER_URL, or a contract bump.
    return {
      action: "transient",
      code: "PARSER_BAD_RESPONSE",
      message: "parser returned 200 without a parse-v1 body",
      status,
      config: true,
    };
  }
  const err = contractError(body);
  if (status === 422 && err && PERMANENT_PARSER_CODES.has(err.code)) {
    return { action: "permanent", code: err.code, message: err.message || err.code, status };
  }
  const code = err ? err.code : `PARSER_HTTP_${status}`;
  const message = err?.message || `parser returned HTTP ${status}`;
  // Load/transient by nature: 408, 429, 5xx. Anything else (401/403/404/405/400/413, a
  // 422 with an unknown code) means the worker and parser disagree: config, not data.
  const config = !(status === 408 || status === 429 || status >= 500);
  return { action: "transient", code, message, status, config };
}

export const DEFAULT_PARSER_TIMEOUT_MS = 75_000;

/** Worker-side HTTP timeout for /parse. The parser kills a parse after 60 s itself (SRV-01). */
export function parserTimeoutMs(): number {
  const v = Number(Deno.env.get("PARSER_TIMEOUT_MS"));
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_PARSER_TIMEOUT_MS;
}

/**
 * SQLSTATEs that mean ingest_parsed_document rejected the payload's content: class 22
 * (data exception: bad date/number/text, 22023 contract checks) plus not-null and check
 * violations. Deterministic for a given parser output, so permanent.
 */
export function isRejectedPayload(sqlstate: string): boolean {
  return sqlstate.startsWith("22") || sqlstate === "23502" || sqlstate === "23514";
}

/**
 * A Postgres error message safe for Sentry: object names (relation/constraint/column/
 * type/function) are kept, any other quoted literal is a value from the statement and
 * is filtered. "Failing row contains (...)" details are never read.
 */
export function sanitizePgMessage(message: unknown): string {
  const text = String(message ?? "").trim() || "(no message)";
  return text
    .replace(
      /(\b(?:relation|constraint|column|table|type|function|index|schema)\s+)?"([^"]*)"/gi,
      (_m, kind: string | undefined, name: string) => (kind ? `${kind}"${name}"` : '"[Filtered]"'),
    )
    .slice(0, 300);
}

/** The constraint name in a check/not-null/unique violation, for Sentry grouping. */
export function pgConstraint(message: unknown): string | null {
  const m = /constraint\s+"([^"]+)"/i.exec(String(message ?? ""));
  return m ? m[1] : null;
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return "invalid";
  }
}

/** Optionally rewrite the signed URL's origin (local dev: kong:8000 → host-reachable URL). */
export function rewriteOrigin(signedUrl: string, base: string | undefined): string {
  if (!base) return signedUrl;
  const u = new URL(signedUrl);
  const b = new URL(base);
  u.protocol = b.protocol;
  u.host = b.host;
  return u.toString();
}

async function failDocument(svc: Db, docCode: string, code: string, message: string, permanent: boolean) {
  await svc.rpc("fail_document", {
    p_doc_code: docCode,
    p_error_code: code,
    p_error: message,
    p_permanent: permanent,
  });
}

interface TransientDetail {
  http_status?: number;
  sqlstate?: string;
  config?: boolean;
  extra?: Record<string, unknown>;
}

export interface ParseResult {
  doc_code: string;
  outcome: "parsed" | "failed" | "retry" | "dlq" | "skipped";
  code?: string;
  warnings?: number;
}

export async function processParseMessage(svc: Db, msg: QueueMessage): Promise<ParseResult> {
  const docCode = String((msg.message as { doc_code?: unknown }).doc_code ?? "");
  if (!/^doc_[0-9a-z]{26}$/.test(docCode)) {
    await toDlq(svc, PARSE_QUEUE, msg, "invalid message");
    return { doc_code: docCode, outcome: "dlq", code: "INVALID_MESSAGE" };
  }
  const attempt = attemptOf(msg);
  const tags = { queue: PARSE_QUEUE, doc_code: docCode, read_ct: msg.read_ct, attempt };

  if (attempt > MAX_READS) {
    await toDlq(svc, PARSE_QUEUE, msg, "max reads exceeded");
    await failDocument(svc, docCode, "MAX_ATTEMPTS", "parsing failed repeatedly; moved to the dead-letter queue", true);
    captureMessage("parse_document moved to DLQ", { level: "error", tags, fingerprint: ["worker", "dlq", PARSE_QUEUE] });
    return { doc_code: docCode, outcome: "dlq", code: "MAX_ATTEMPTS" };
  }

  const { data: ctx, error: ctxErr } = await svc.rpc("worker_document_context", { p_doc_code: docCode });
  if (ctxErr) throw new Error(`worker_document_context failed (${ctxErr.code})`);
  if (!ctx || !ctx.doc) {
    await queueDelete(svc, PARSE_QUEUE, msg.msg_id); // document was deleted
    return { doc_code: docCode, outcome: "skipped" };
  }
  const doc = ctx.doc as { storage_path: string; original_filename: string; bank_code: string | null; profile_code: string };

  await svc.from("documents").update({ parse_status: "parsing", parse_attempts: Math.min(attempt, 32767) })
    .eq("doc_code", docCode);

  const handleTransient = async (
    code: string,
    message: string,
    detail: TransientDetail = {},
  ): Promise<ParseResult> => {
    const extra: Record<string, unknown> = { error_code: code, error_message: message, ...detail.extra };
    const detailTags = {
      ...(detail.http_status !== undefined ? { http_status: detail.http_status } : {}),
      ...(detail.sqlstate ? { sqlstate: detail.sqlstate } : {}),
    };
    if (attempt >= MAX_READS) {
      await toDlq(svc, PARSE_QUEUE, msg, code);
      await failDocument(svc, docCode, code, message, true);
      captureMessage(`parse_document moved to DLQ: ${code}`, {
        level: "error",
        tags: { ...tags, ...detailTags, error_code: code },
        extra,
        fingerprint: ["worker", "dlq", PARSE_QUEUE, code],
      });
      return { doc_code: docCode, outcome: "dlq", code };
    }
    await failDocument(svc, docCode, code, message, false); // back to 'queued'
    // Backoff (60 s, 5 min, 15 min, 30 min): a misconfiguration gets ~50 min to be fixed
    // before documents dead-letter. Falls back to the visibility timeout if the re-send fails.
    const delay = await retryLater(svc, PARSE_QUEUE, msg, attempt);
    extra.retry_in_s = delay ?? "visibility timeout";
    if (detail.config) {
      // The parser endpoint answered with something the contract doesn't allow: a wrong
      // PARSER_URL, an IAM/ingress change, a secret mismatch. Loud, and grouped per status.
      captureMessage(`parser endpoint misconfigured or unexpected response (HTTP ${detail.http_status})`, {
        level: "error",
        tags: { ...tags, ...detailTags, error_code: code },
        extra,
        fingerprint: ["worker", "parser_config", String(detail.http_status ?? code)],
      });
    } else {
      captureMessage(`parse_document attempt failed: ${code}`, {
        level: "warning",
        tags: { ...tags, ...detailTags, error_code: code },
        extra,
        fingerprint: ["worker", "parse_transient", code],
      });
    }
    return { doc_code: docCode, outcome: "retry", code };
  };

  const signed = await svc.storage.from("statements").createSignedUrl(doc.storage_path, 600);
  if (signed.error || !signed.data?.signedUrl) {
    // deno-lint-ignore no-explicit-any
    const se = signed.error as any;
    if (se && (se.status === 404 || String(se.statusCode) === "404" || /not.?found/i.test(String(se.message)))) {
      await failDocument(svc, docCode, "DOCUMENT_MISSING", "the PDF is not in storage", true);
      await queueDelete(svc, PARSE_QUEUE, msg.msg_id);
      return { doc_code: docCode, outcome: "failed", code: "DOCUMENT_MISSING" };
    }
    return await handleTransient("SIGNED_URL_FAILED", "could not sign the document URL", {
      extra: { storage_status: se?.statusCode ?? se?.status, storage_error: String(se?.message ?? "").slice(0, 200) },
    });
  }
  const documentUrl = rewriteOrigin(signed.data.signedUrl, Deno.env.get("PARSER_DOCUMENT_BASE_URL") || undefined);

  const parserUrl = (Deno.env.get("PARSER_URL") ?? "").replace(/\/+$/, "");
  const parserSecret = Deno.env.get("PARSER_SECRET") ?? "";
  if (!parserUrl || !parserSecret) return await handleTransient("PARSER_NOT_CONFIGURED", "PARSER_URL / PARSER_SECRET not set");

  let res: Response;
  let body: unknown = null;
  try {
    res = await fetch(`${parserUrl}/parse`, {
      method: "POST",
      headers: { "content-type": "application/json", "X-Parser-Secret": parserSecret, ...traceHeaders() },
      body: JSON.stringify({
        document_url: documentUrl,
        filename: doc.original_filename,
        bank_code_hint: doc.bank_code,
        settings: ctx.settings ?? {},
      }),
      signal: AbortSignal.timeout(parserTimeoutMs()),
    });
    body = await res.json().catch(() => null);
  } catch (e) {
    const timedOut = e instanceof DOMException && e.name === "TimeoutError";
    const code = timedOut ? "PARSER_TIMEOUT" : "PARSER_UNREACHABLE";
    const reason = timedOut ? `no response within ${parserTimeoutMs()} ms` : `${(e as Error)?.name ?? "Error"}`;
    return await handleTransient(code, `parser request failed: ${reason}`, { extra: { parser_host: hostOf(parserUrl) } });
  }

  const outcome = classifyParserResponse(res.status, body);
  if (outcome.action === "transient") {
    return await handleTransient(outcome.code, outcome.message, { http_status: outcome.status, config: outcome.config });
  }
  if (outcome.action === "permanent") {
    await failDocument(svc, docCode, outcome.code, outcome.message, true);
    await queueDelete(svc, PARSE_QUEUE, msg.msg_id);
    captureMessage(`document parse failed permanently: ${outcome.code}`, {
      level: "warning",
      tags: { ...tags, error_code: outcome.code, http_status: outcome.status, bank_code: doc.bank_code ?? undefined },
      extra: { error_message: outcome.message },
      fingerprint: ["worker", "parse_permanent", outcome.code],
    });
    return { doc_code: docCode, outcome: "failed", code: outcome.code };
  }

  const ing = await svc.rpc("ingest_parsed_document", { p_doc_code: docCode, p_payload: outcome.payload });
  if (ing.error) {
    const sqlstate = String(ing.error.code ?? "");
    const pgMessage = sanitizePgMessage(ing.error.message);
    if (isRejectedPayload(sqlstate)) {
      // The payload itself is unacceptable: the same PDF gives the same output, so retrying won't help.
      await failDocument(svc, docCode, `INGEST_${sqlstate}`, String(ing.error.message ?? "").slice(0, 500), true);
      await queueDelete(svc, PARSE_QUEUE, msg.msg_id);
      captureMessage(`ingest_parsed_document rejected parser output (${sqlstate}): ${pgMessage}`, {
        level: "error",
        tags: { ...tags, sqlstate, bank_code: doc.bank_code ?? undefined },
        extra: { sqlstate, pg_message: pgMessage, parser_version: outcome.payload.parser_version },
        fingerprint: ["worker", "ingest_rejected", sqlstate, pgConstraint(ing.error.message) ?? ""],
      });
      return { doc_code: docCode, outcome: "failed", code: `INGEST_${sqlstate}` };
    }
    if (sqlstate === "P0002") {
      await queueDelete(svc, PARSE_QUEUE, msg.msg_id);
      return { doc_code: docCode, outcome: "skipped" };
    }
    return await handleTransient(`INGEST_${sqlstate || "ERROR"}`, `ingest failed: ${pgMessage}`, {
      sqlstate: sqlstate || undefined,
      extra: { sqlstate, pg_message: pgMessage },
    });
  }
  await queueDelete(svc, PARSE_QUEUE, msg.msg_id);
  // Ingest warnings are statement kind/date notes (e.g. "statement 2026-01-28 skipped: no card
  // number and no transaction rows"), never amounts or descriptions.
  const warnings = ingestWarnings(ing.data);
  if (warnings.length) console.log(`worker: ${docCode} ingested with ${warnings.length} warning(s):`, warnings.slice(0, 5));
  return { doc_code: docCode, outcome: "parsed", ...(warnings.length ? { warnings: warnings.length } : {}) };
}

/** The `warnings` array of ingest_parsed_document's result (strings only, capped). */
export function ingestWarnings(result: unknown): string[] {
  const w = result && typeof result === "object" ? (result as { warnings?: unknown }).warnings : null;
  return Array.isArray(w) ? w.filter((x): x is string => typeof x === "string").map((x) => x.slice(0, 200)) : [];
}
