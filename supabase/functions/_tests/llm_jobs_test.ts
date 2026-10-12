// llm_categorize / sms_fallback consumers against the 2026-10-09 RPC contracts, with a
// fake Db and a fake Anthropic endpoint (no network, no real key).

import { assertEquals } from "jsr:@std/assert@1.0.13";
import { processLlmCategorize, processSmsFallback } from "../worker/llm_jobs.ts";
import { FakeDb } from "./fake_db.ts";

Deno.env.delete("SENTRY_DSN");
Deno.env.set("ANTHROPIC_API_KEY", "test-key-not-real");

// The SDK keeps the fetch it finds when the client is created, so install one
// dispatcher before the first call and swap its answer per test.
let answer: unknown = {};
let llmCalls = 0;
const realFetch = globalThis.fetch;
globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (!url.startsWith("https://api.anthropic.com/")) return realFetch(input, init);
  llmCalls++;
  return Promise.resolve(Response.json({
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-test",
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: 1, output_tokens: 1 },
    content: [{ type: "text", text: JSON.stringify(answer) }],
  }));
}) as typeof fetch;

Deno.test("llm_categorize passes the batch's merchant codes to apply_llm_suggestions (DB-37)", async () => {
  answer = { suggestions: [{ merchant: "m1", category: "c1", confidence: 0.9 }] };
  const db = new FakeDb({
    rpcs: {
      worker_llm_context: () => ({
        data: {
          categories: [{ category_code: "cat_food", name: "Food", kind: "spend" }],
          merchants: [{ merchant_code: "mer_a", name: "A" }, { merchant_code: "mer_b", name: "B" }],
          category_set_hash: "h1",
        },
        error: null,
      }),
      apply_llm_suggestions: () => ({ data: 1, error: null }),
      queue_delete: () => ({ data: true, error: null }),
    },
  });
  const r = await processLlmCategorize(db.asDb(), {
    msg_id: 1,
    read_ct: 1,
    message: { profile_code: "prf_x", merchant_codes: ["mer_a", "mer_b"] },
  });
  assertEquals(r, { queue: "llm_categorize", outcome: "done", applied: 1 });
  const call = db.rpcCalls("apply_llm_suggestions")[0];
  assertEquals(call.p_merchant_codes, ["mer_a", "mer_b"], "mer_b (declined) is reported too");
  assertEquals(call.p_category_set_hash, "h1");
  assertEquals(
    call.p_suggestions,
    [{ merchant_code: "mer_a", category_code: "cat_food", confidence: 0.9 }],
    "refs are mapped back to codes",
  );
});

Deno.test("llm_categorize asks about at most LLM_BATCH_MAX (100) merchants per call", async () => {
  answer = { suggestions: [] };
  const db = new FakeDb({
    rpcs: {
      worker_llm_context: () => ({ data: { categories: [], merchants: [], category_set_hash: "h1" }, error: null }),
      queue_delete: () => ({ data: true, error: null }),
    },
  });
  const codes = Array.from({ length: 150 }, (_, i) => `mer_${i}`);
  await processLlmCategorize(db.asDb(), {
    msg_id: 2,
    read_ct: 1,
    message: { profile_code: "prf_x", merchant_codes: codes },
  });
  assertEquals(db.rpcCalls("worker_llm_context")[0].p_merchant_codes, codes.slice(0, 100));
});

Deno.test("sms_fallback: a message without a sender is skipped before the LLM, not dead-lettered", async () => {
  const callsBefore = llmCalls;
  const db = new FakeDb({
    rpcs: {
      worker_sms_context: () => ({
        data: {
          parse_status: "unparsed",
          sender: " ",
          body: "synthetic",
          banks: [{ bank_code: "ADCB", senders: ["ADCBAlert"] }],
        },
        error: null,
      }),
      queue_delete: () => ({ data: true, error: null }),
    },
  });
  const r = await processSmsFallback(db.asDb(), {
    msg_id: 6,
    read_ct: 1,
    message: { sms_code: "sms_01m4rcavc3xxeanad83pcwbwgc" },
  });
  assertEquals(r, { queue: "sms_fallback", outcome: "skipped", code: "NO_SENDER" });
  assertEquals(db.rpcCalls("queue_delete").length, 1);
  assertEquals(db.rpcCalls("queue_to_dlq").length, 0);
  assertEquals(db.rpcCalls("propose_sms_template").length, 0);
  assertEquals(llmCalls - callsBefore, 0, "no model call");
});

Deno.test("sms_fallback: propose_sms_template 22023 (sender not the bank's) dead-letters once", async () => {
  answer = {
    bank_code: "ADCB",
    name: "purchase alert",
    sender_pattern: ".*",
    body_pattern: "(AED|USD) ([0-9,]+(?:\\.[0-9]+)?) .*?card (?:ending )?([0-9]{4}) at (.+?)\\.",
    field_groups: { amount: 2, currency: 1, last4: 3, merchant: 4, date: null, time: null, available: null },
    date_format: null,
    msg_kind: "purchase",
    expect: { amount: "1,052.5", currency: "aed", last4: "x3687", merchant: " Carrefour  city " },
  };
  const db = new FakeDb({
    rpcs: {
      worker_sms_context: () => ({
        data: {
          parse_status: "unparsed",
          sender: "SPOOF",
          body: "synthetic",
          banks: [{ bank_code: "ADCB", senders: ["ADCBAlert"] }],
        },
        error: null,
      }),
      propose_sms_template: () => ({
        data: null,
        error: { code: "22023", message: "sender SPOOF is not a sender of ADCB" },
      }),
      queue_to_dlq: () => ({ data: null, error: null }),
    },
  });
  const r = await processSmsFallback(db.asDb(), {
    msg_id: 5,
    read_ct: 1,
    message: { sms_code: "sms_01m4db8acd3wgrmddfx4a4k3sc" },
  });
  assertEquals(r, { queue: "sms_fallback", outcome: "dlq", code: "PROPOSE_22023" });
  const dlq = db.rpcCalls("queue_to_dlq");
  assertEquals(dlq.length, 1, "no retry");
  assertEquals(dlq[0].p_reason, "PROPOSE_22023: propose_sms_template sqlstate 22023", "no SMS text in the reason");
});
