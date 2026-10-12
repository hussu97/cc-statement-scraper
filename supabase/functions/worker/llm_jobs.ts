// llm_categorize and sms_fallback queue consumers.

import { captureMessage } from "../_shared/sentry.ts";
import type { Db } from "../_shared/supabase.ts";
import {
  CATEGORIZE_SYSTEM,
  categorizeSchema,
  categorizeUserPrompt,
  isTransientLlmError,
  LLM_BATCH_MAX,
  type LlmCategory,
  llmErrorReason,
  type LlmMerchant,
  llmModel,
  LlmNotApplicable,
  SMS_SYSTEM,
  smsTemplateSchema,
  smsUserPrompt,
  structuredCall,
  validateSuggestions,
  validateTemplateProposal,
} from "../_shared/llm.ts";
import { MAX_READS, queueDelete, type QueueMessage, toDlq } from "./queue.ts";

export const LLM_QUEUE = "llm_categorize";
export const SMS_QUEUE = "sms_fallback";

export interface JobResult {
  queue: string;
  outcome: "done" | "retry" | "dlq" | "skipped";
  code?: string;
  applied?: number;
}

async function retryOrDlq(
  svc: Db,
  queue: string,
  msg: QueueMessage,
  code: string,
  tags: Record<string, string | number>,
  reason: string,
) {
  if (msg.read_ct >= MAX_READS) {
    await toDlq(svc, queue, msg, `${code}: ${reason}`);
    captureMessage(`${queue} moved to DLQ: ${code} (${reason})`, {
      level: "error",
      tags: { ...tags, error_code: code, reason },
      fingerprint: ["worker", "dlq", queue, code],
    });
    return "dlq" as const;
  }
  captureMessage(`${queue} attempt failed: ${code} (${reason})`, {
    level: "warning",
    tags: { ...tags, error_code: code, reason },
    fingerprint: ["worker", `${queue}_transient`, code],
  });
  return "retry" as const;
}

/** Deterministic failure: dead-letter once, with the reason, and never retry. */
async function dlqOnce(
  svc: Db,
  queue: string,
  msg: QueueMessage,
  code: string,
  tags: Record<string, string | number>,
  reason: string,
) {
  await toDlq(svc, queue, msg, `${code}: ${reason}`);
  captureMessage(`${queue} moved to DLQ: ${code} (${reason})`, {
    level: "warning",
    tags: { ...tags, error_code: code, reason },
    fingerprint: ["worker", "dlq", queue, code, reason],
  });
}

function errCode(e: unknown): string {
  // deno-lint-ignore no-explicit-any
  const status = (e as any)?.status;
  if (typeof status === "number") return `LLM_HTTP_${status}`;
  return (e as Error)?.name === "LlmOutputError" ? "LLM_BAD_OUTPUT" : "LLM_ERROR";
}

export async function processLlmCategorize(svc: Db, msg: QueueMessage): Promise<JobResult> {
  const m = msg.message as { profile_code?: string; merchant_codes?: string[] };
  const tags = { queue: LLM_QUEUE, profile_code: String(m.profile_code ?? ""), read_ct: msg.read_ct };
  if (!m.profile_code || !Array.isArray(m.merchant_codes) || m.merchant_codes.length === 0) {
    await toDlq(svc, LLM_QUEUE, msg, "invalid message");
    return { queue: LLM_QUEUE, outcome: "dlq", code: "INVALID_MESSAGE" };
  }
  const { data: ctx, error } = await svc.rpc("worker_llm_context", {
    p_profile_code: m.profile_code,
    p_merchant_codes: m.merchant_codes.slice(0, LLM_BATCH_MAX),
  });
  if (error) throw new Error(`worker_llm_context failed (${error.code})`);
  const categories = (ctx?.categories ?? []) as LlmCategory[];
  const merchants = (ctx?.merchants ?? []) as LlmMerchant[];
  if (categories.length === 0 || merchants.length === 0) {
    await queueDelete(svc, LLM_QUEUE, msg.msg_id);
    return { queue: LLM_QUEUE, outcome: "skipped" };
  }
  const merchantCodes = merchants.map((x) => x.merchant_code);
  const categoryCodes = categories.map((x) => x.category_code);
  try {
    const raw = await structuredCall({
      system: CATEGORIZE_SYSTEM,
      user: categorizeUserPrompt(categories, merchants),
      schema: categorizeSchema(merchantCodes.length, categoryCodes.length),
    });
    const suggestions = validateSuggestions(raw, merchantCodes, categoryCodes);
    const { data: applied, error: applyErr } = await svc.rpc("apply_llm_suggestions", {
      p_profile_code: m.profile_code,
      p_suggestions: suggestions,
      p_model: llmModel(),
      p_category_set_hash: ctx.category_set_hash,
      // The batch asked about: merchants the model declined are recorded per category set
      // (merchant_category_skips) and not re-enqueued every night (DB-37).
      p_merchant_codes: merchantCodes,
    });
    if (applyErr) throw new Error(`apply_llm_suggestions failed (${applyErr.code})`);
    await queueDelete(svc, LLM_QUEUE, msg.msg_id);
    return { queue: LLM_QUEUE, outcome: "done", applied: Number(applied ?? 0) };
  } catch (e) {
    const code = errCode(e);
    const reason = llmErrorReason(e);
    if (!isTransientLlmError(e)) {
      await dlqOnce(svc, LLM_QUEUE, msg, code, tags, reason);
      return { queue: LLM_QUEUE, outcome: "dlq", code };
    }
    return { queue: LLM_QUEUE, outcome: await retryOrDlq(svc, LLM_QUEUE, msg, code, tags, reason), code };
  }
}

export async function processSmsFallback(svc: Db, msg: QueueMessage): Promise<JobResult> {
  const smsCode = String((msg.message as { sms_code?: unknown }).sms_code ?? "");
  const tags = { queue: SMS_QUEUE, sms_code: smsCode, read_ct: msg.read_ct };
  if (!/^sms_[0-9a-z]{26}$/.test(smsCode)) {
    await toDlq(svc, SMS_QUEUE, msg, "invalid message");
    return { queue: SMS_QUEUE, outcome: "dlq", code: "INVALID_MESSAGE" };
  }
  const { data: ctx, error } = await svc.rpc("worker_sms_context", { p_sms_code: smsCode });
  if (error) throw new Error(`worker_sms_context failed (${error.code})`);
  if (!ctx || ctx.parse_status !== "unparsed") {
    // Deleted, or a template has parsed it since it was queued.
    await queueDelete(svc, SMS_QUEUE, msg.msg_id);
    return { queue: SMS_QUEUE, outcome: "skipped" };
  }
  if (String(ctx.sender ?? "").trim() === "") {
    // No sender (a hand-typed test, or a Shortcut not passing Sender): propose_sms_template
    // anchors every template on the bank's senders, so nothing can be learned. The SMS stays
    // 'unparsed' for the review UI; no LLM call, no DLQ, no alert.
    await queueDelete(svc, SMS_QUEUE, msg.msg_id);
    return { queue: SMS_QUEUE, outcome: "skipped", code: "NO_SENDER" };
  }
  const banks = (ctx.banks ?? []) as { bank_code: string; senders: string[] }[];
  const bankCodes = banks.map((b) => b.bank_code);
  if (bankCodes.length === 0) {
    // An empty enum is an invalid schema (Anthropic 400): don't call the model at all.
    await dlqOnce(svc, SMS_QUEUE, msg, "NO_BANKS", tags, "no banks configured");
    return { queue: SMS_QUEUE, outcome: "dlq", code: "NO_BANKS" };
  }
  let proposal;
  try {
    const raw = await structuredCall({
      system: SMS_SYSTEM,
      user: smsUserPrompt(String(ctx.sender ?? ""), String(ctx.body ?? ""), banks),
      schema: smsTemplateSchema(bankCodes),
    });
    proposal = validateTemplateProposal(raw, bankCodes);
  } catch (e) {
    if (e instanceof LlmNotApplicable) {
      // Not a card transaction (OTP, promotion, the e2e probe): nothing to learn. The SMS
      // stays 'unparsed' for the review UI; no DLQ, no alert.
      await queueDelete(svc, SMS_QUEUE, msg.msg_id);
      return { queue: SMS_QUEUE, outcome: "skipped", code: "NOT_A_TRANSACTION" };
    }
    const code = errCode(e);
    const reason = llmErrorReason(e);
    if (!isTransientLlmError(e)) {
      await dlqOnce(svc, SMS_QUEUE, msg, code, tags, reason);
      return { queue: SMS_QUEUE, outcome: "dlq", code };
    }
    return { queue: SMS_QUEUE, outcome: await retryOrDlq(svc, SMS_QUEUE, msg, code, tags, reason), code };
  }

  const { error: propErr } = await svc.rpc("propose_sms_template", { p_sms_code: smsCode, p_template: proposal });
  if (propErr) {
    // The DB validates the template against this very message; its error text quotes
    // the SMS, so only the SQLSTATE is ever recorded. 22023 includes "the sender is not
    // one of the bank's senders" (the DB ignores the model's sender regex): retrying the
    // same message can never succeed, so these dead-letter once.
    const code = `PROPOSE_${propErr.code ?? "ERROR"}`;
    const reason = `propose_sms_template sqlstate ${propErr.code ?? "unknown"}`;
    if (["22023", "23503", "23514", "2201B", "22P02"].includes(propErr.code ?? "")) {
      await dlqOnce(svc, SMS_QUEUE, msg, code, tags, reason);
      return { queue: SMS_QUEUE, outcome: "dlq", code };
    }
    return { queue: SMS_QUEUE, outcome: await retryOrDlq(svc, SMS_QUEUE, msg, code, tags, reason), code };
  }
  await queueDelete(svc, SMS_QUEUE, msg.msg_id);
  return { queue: SMS_QUEUE, outcome: "done" };
}
