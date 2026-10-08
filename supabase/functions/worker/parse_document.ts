// parse_document queue consumer: signed URL → parser /parse → ingest_parsed_document.

import { captureMessage, traceHeaders } from "../_shared/sentry.ts";
import type { Db } from "../_shared/supabase.ts";
import { MAX_READS, type QueueMessage, queueDelete, toDlq } from "./queue.ts";

export const PARSE_QUEUE = "parse_document";

export type ParserOutcome =
  | { action: "ingest"; payload: Record<string, unknown> }
  | { action: "permanent"; code: string; message: string }
  | { action: "transient"; code: string; message: string };

/** Decide what to do with a parser HTTP response (contract parse-v1, "Response 4xx/5xx"). */
export function classifyParserResponse(status: number, body: unknown): ParserOutcome {
  const err = (body && typeof body === "object" ? (body as { error?: { code?: string; message?: string } }).error : null) ??
    null;
  const code = String(err?.code ?? `HTTP_${status}`).slice(0, 64);
  const message = String(err?.message ?? `parser returned HTTP ${status}`).slice(0, 500);
  if (status === 200) {
    if (body && typeof body === "object" && (body as { contract_version?: unknown }).contract_version === 1) {
      return { action: "ingest", payload: body as Record<string, unknown> };
    }
    return { action: "permanent", code: "BAD_PARSER_RESPONSE", message: "parser returned an unsupported contract" };
  }
  // 401 = shared-secret mismatch (config), 408/429 = load: retry, never fail the document.
  if (status === 401 || status === 408 || status === 429 || status >= 500) return { action: "transient", code, message };
  if (status >= 400) return { action: "permanent", code, message };
  return { action: "transient", code, message };
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

export interface ParseResult {
  doc_code: string;
  outcome: "parsed" | "failed" | "retry" | "dlq" | "skipped";
  code?: string;
}

export async function processParseMessage(svc: Db, msg: QueueMessage): Promise<ParseResult> {
  const docCode = String((msg.message as { doc_code?: unknown }).doc_code ?? "");
  if (!/^doc_[0-9a-z]{26}$/.test(docCode)) {
    await toDlq(svc, PARSE_QUEUE, msg, "invalid message");
    return { doc_code: docCode, outcome: "dlq", code: "INVALID_MESSAGE" };
  }
  const tags = { queue: PARSE_QUEUE, doc_code: docCode, read_ct: msg.read_ct };

  if (msg.read_ct > MAX_READS) {
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

  await svc.from("documents").update({ parse_status: "parsing", parse_attempts: Math.min(msg.read_ct, 32767) })
    .eq("doc_code", docCode);

  const handleTransient = async (code: string, message: string): Promise<ParseResult> => {
    if (msg.read_ct >= MAX_READS) {
      await toDlq(svc, PARSE_QUEUE, msg, code);
      await failDocument(svc, docCode, code, message, true);
      captureMessage("parse_document moved to DLQ", {
        level: "error",
        tags: { ...tags, error_code: code },
        fingerprint: ["worker", "dlq", PARSE_QUEUE],
      });
      return { doc_code: docCode, outcome: "dlq", code };
    }
    await failDocument(svc, docCode, code, message, false); // back to 'queued'; vt expiry retries
    captureMessage("parse_document attempt failed", {
      level: "warning",
      tags: { ...tags, error_code: code },
      fingerprint: ["worker", "parse_transient", code],
    });
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
    return await handleTransient("SIGNED_URL_FAILED", "could not sign the document URL");
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
      signal: AbortSignal.timeout(Number(Deno.env.get("PARSER_TIMEOUT_MS") ?? "100000")),
    });
    body = await res.json().catch(() => null);
  } catch (e) {
    const code = e instanceof DOMException && e.name === "TimeoutError" ? "PARSER_TIMEOUT" : "PARSER_UNREACHABLE";
    return await handleTransient(code, `parser request failed: ${code}`);
  }

  const outcome = classifyParserResponse(res.status, body);
  if (outcome.action === "transient") return await handleTransient(outcome.code, outcome.message);
  if (outcome.action === "permanent") {
    await failDocument(svc, docCode, outcome.code, outcome.message, true);
    await queueDelete(svc, PARSE_QUEUE, msg.msg_id);
    captureMessage("document parse failed permanently", {
      level: "warning",
      tags: { ...tags, error_code: outcome.code, bank_code: doc.bank_code ?? undefined },
      fingerprint: ["worker", "parse_permanent", outcome.code],
    });
    return { doc_code: docCode, outcome: "failed", code: outcome.code };
  }

  const ing = await svc.rpc("ingest_parsed_document", { p_doc_code: docCode, p_payload: outcome.payload });
  if (ing.error) {
    const sqlstate = ing.error.code ?? "";
    if (sqlstate === "22023" || sqlstate === "23514" || sqlstate === "23502" || sqlstate === "22P02") {
      // The payload itself is unacceptable: retrying the same parser output won't help.
      await failDocument(svc, docCode, `INGEST_${sqlstate}`, String(ing.error.message).slice(0, 500), true);
      await queueDelete(svc, PARSE_QUEUE, msg.msg_id);
      captureMessage("ingest_parsed_document rejected parser output", {
        level: "error",
        tags: { ...tags, sqlstate },
        fingerprint: ["worker", "ingest_rejected", sqlstate],
      });
      return { doc_code: docCode, outcome: "failed", code: `INGEST_${sqlstate}` };
    }
    if (sqlstate === "P0002") {
      await queueDelete(svc, PARSE_QUEUE, msg.msg_id);
      return { doc_code: docCode, outcome: "skipped" };
    }
    return await handleTransient(`INGEST_${sqlstate || "ERROR"}`, "ingest failed");
  }
  await queueDelete(svc, PARSE_QUEUE, msg.msg_id);
  return { doc_code: docCode, outcome: "parsed" };
}
