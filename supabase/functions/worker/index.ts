// worker: pgmq consumer, woken every minute by pg_cron (private.kick_worker →
// invoke_edge, header x-cron-secret) when a queue has visible messages.
//
// Queues, in priority order per round:
//   parse_document  (vt 300s, 3 at a time) → parser /parse → ingest_parsed_document
//   llm_categorize  (vt 300s, 2 at a time) → Claude → apply_llm_suggestions
//   sms_fallback    (vt 300s, 2 at a time) → Claude → propose_sms_template
// A failing message is retried by visibility timeout and dead-lettered after 5 reads.
//
// pg_net gives up after 5s, so by default the work runs in the background
// (EdgeRuntime.waitUntil) and the call returns 202. `{"sync": true}` (or ?sync=1)
// waits and returns the summary, which tests and manual runs use.

import { captureException, withSentry } from "../_shared/sentry.ts";
import { runCronJob } from "../_shared/cron.ts";
import { requireCron } from "../_shared/auth.ts";
import { requireMethod } from "../_shared/http.ts";
import { type Db, serviceClient } from "../_shared/supabase.ts";
import { llmConfigured } from "../_shared/llm.ts";
import { queueRead } from "./queue.ts";
import { PARSE_QUEUE, processParseMessage } from "./parse_document.ts";
import { LLM_QUEUE, processLlmCategorize, processSmsFallback, SMS_QUEUE } from "./llm_jobs.ts";

const VT_SECONDS = 300;
let warnedNoLlm = false;

interface Summary {
  rounds: number;
  parse: unknown[];
  llm: unknown[];
  sms: unknown[];
  errors: number;
  llm_enabled: boolean;
  elapsed_ms: number;
}

async function settle<T>(items: T[], fn: (x: T) => Promise<unknown>, out: unknown[], summary: Summary) {
  const results = await Promise.allSettled(items.map(fn));
  for (const r of results) {
    if (r.status === "fulfilled") out.push(r.value);
    else {
      summary.errors++;
      captureException(r.reason, { tags: { function: "worker" } });
    }
  }
}

export async function runWorker(svc: Db, budgetMs: number): Promise<Summary> {
  const started = Date.now();
  const deadline = started + budgetMs;
  const llm = llmConfigured();
  if (!llm && !warnedNoLlm) {
    console.warn("worker: ANTHROPIC_API_KEY not set; llm_categorize and sms_fallback messages are left queued");
    warnedNoLlm = true;
  }
  const summary: Summary = { rounds: 0, parse: [], llm: [], sms: [], errors: 0, llm_enabled: llm, elapsed_ms: 0 };

  while (Date.now() < deadline) {
    summary.rounds++;
    let seen = 0;

    const parseMsgs = await queueRead(svc, PARSE_QUEUE, VT_SECONDS, 3);
    seen += parseMsgs.length;
    await settle(parseMsgs, (m) => processParseMessage(svc, m), summary.parse, summary);

    if (llm && Date.now() < deadline) {
      const llmMsgs = await queueRead(svc, LLM_QUEUE, VT_SECONDS, 2);
      seen += llmMsgs.length;
      await settle(llmMsgs, (m) => processLlmCategorize(svc, m), summary.llm, summary);
    }
    if (llm && Date.now() < deadline) {
      const smsMsgs = await queueRead(svc, SMS_QUEUE, VT_SECONDS, 2);
      seen += smsMsgs.length;
      await settle(smsMsgs, (m) => processSmsFallback(svc, m), summary.sms, summary);
    }
    if (seen === 0) break;
  }
  summary.elapsed_ms = Date.now() - started;
  return summary;
}

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);
  const budget = Number(Deno.env.get("WORKER_BUDGET_MS") ?? "50000");
  return await runCronJob(req, "worker", () => runWorker(serviceClient(), budget));
}

Deno.serve(withSentry("worker", handler));
