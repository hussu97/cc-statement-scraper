// llm_categorize and sms_fallback queue consumers.

import { captureMessage } from "../_shared/sentry.ts";
import type { Db } from "../_shared/supabase.ts";
import {
  CATEGORIZE_SYSTEM,
  categorizeSchema,
  categorizeUserPrompt,
  isTransientLlmError,
  type LlmCategory,
  type LlmMerchant,
  llmModel,
  SMS_SYSTEM,
  smsTemplateSchema,
  smsUserPrompt,
  structuredCall,
  validateSuggestions,
  validateTemplateProposal,
} from "../_shared/llm.ts";
import { MAX_READS, type QueueMessage, queueDelete, toDlq } from "./queue.ts";

export const LLM_QUEUE = "llm_categorize";
export const SMS_QUEUE = "sms_fallback";

export interface JobResult {
  queue: string;
  outcome: "done" | "retry" | "dlq" | "skipped";
  code?: string;
  applied?: number;
}

async function retryOrDlq(svc: Db, queue: string, msg: QueueMessage, code: string, tags: Record<string, string | number>) {
  if (msg.read_ct >= MAX_READS) {
    await toDlq(svc, queue, msg, code);
    captureMessage(`${queue} moved to DLQ`, { level: "error", tags: { ...tags, error_code: code }, fingerprint: ["worker", "dlq", queue] });
    return "dlq" as const;
  }
  captureMessage(`${queue} attempt failed`, { level: "warning", tags: { ...tags, error_code: code }, fingerprint: ["worker", `${queue}_transient`] });
  return "retry" as const;
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
    p_merchant_codes: m.merchant_codes.slice(0, 50),
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
      schema: categorizeSchema(merchantCodes, categoryCodes),
    });
    const suggestions = validateSuggestions(raw, merchantCodes, categoryCodes);
    const { data: applied, error: applyErr } = await svc.rpc("apply_llm_suggestions", {
      p_profile_code: m.profile_code,
      p_suggestions: suggestions,
      p_model: llmModel(),
      p_category_set_hash: ctx.category_set_hash,
    });
    if (applyErr) throw new Error(`apply_llm_suggestions failed (${applyErr.code})`);
    await queueDelete(svc, LLM_QUEUE, msg.msg_id);
    return { queue: LLM_QUEUE, outcome: "done", applied: Number(applied ?? 0) };
  } catch (e) {
    const code = errCode(e);
    if (!isTransientLlmError(e)) {
      await toDlq(svc, LLM_QUEUE, msg, code);
      captureMessage(`${LLM_QUEUE} moved to DLQ`, { level: "error", tags: { ...tags, error_code: code }, fingerprint: ["worker", "dlq", LLM_QUEUE] });
      return { queue: LLM_QUEUE, outcome: "dlq", code };
    }
    return { queue: LLM_QUEUE, outcome: await retryOrDlq(svc, LLM_QUEUE, msg, code, tags), code };
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
  const banks = ((ctx.banks ?? []) as { bank_code: string; senders: string[] }[]);
  const bankCodes = banks.map((b) => b.bank_code);
  let proposal;
  try {
    const raw = await structuredCall({
      system: SMS_SYSTEM,
      user: smsUserPrompt(String(ctx.sender ?? ""), String(ctx.body ?? ""), banks),
      schema: smsTemplateSchema(bankCodes),
    });
    proposal = validateTemplateProposal(raw, bankCodes);
  } catch (e) {
    const code = errCode(e);
    if (!isTransientLlmError(e)) {
      await toDlq(svc, SMS_QUEUE, msg, code);
      captureMessage(`${SMS_QUEUE} moved to DLQ`, { level: "warning", tags: { ...tags, error_code: code }, fingerprint: ["worker", "dlq", SMS_QUEUE] });
      return { queue: SMS_QUEUE, outcome: "dlq", code };
    }
    return { queue: SMS_QUEUE, outcome: await retryOrDlq(svc, SMS_QUEUE, msg, code, tags), code };
  }

  const { error: propErr } = await svc.rpc("propose_sms_template", { p_sms_code: smsCode, p_template: proposal });
  if (propErr) {
    // The DB validates the template against this very message; its error text quotes
    // the SMS, so only the SQLSTATE is ever recorded.
    const code = `PROPOSE_${propErr.code ?? "ERROR"}`;
    if (["22023", "23503", "23514", "2201B", "22P02"].includes(propErr.code ?? "")) {
      await toDlq(svc, SMS_QUEUE, msg, code);
      return { queue: SMS_QUEUE, outcome: "dlq", code };
    }
    return { queue: SMS_QUEUE, outcome: await retryOrDlq(svc, SMS_QUEUE, msg, code, tags), code };
  }
  await queueDelete(svc, SMS_QUEUE, msg.msg_id);
  return { queue: SMS_QUEUE, outcome: "done" };
}
