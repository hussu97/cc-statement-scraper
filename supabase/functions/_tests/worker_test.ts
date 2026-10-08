// Worker state machine (SRV-03, SRV-04, SRV-11 subset, X-06 reporting, sms_fallback DLQ)
// with a fake Db and a fake parser fetch. Sentry is off (no DSN) so nothing is sent.

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1.0.13";
import {
  classifyParserResponse,
  ingestWarnings,
  isRejectedPayload,
  PERMANENT_PARSER_CODES,
  pgConstraint,
  processParseMessage,
  sanitizePgMessage,
} from "../worker/parse_document.ts";
import { canStart, llmRoundNeedMs, parseRoundNeedMs, type WorkerTiming } from "../worker/budget.ts";
import { attemptOf, backoffSeconds, MAX_READS, type QueueMessage } from "../worker/queue.ts";
import { processSmsFallback } from "../worker/llm_jobs.ts";
import { llmErrorReason, LlmNotApplicable, LlmOutputError, validateTemplateProposal } from "../_shared/llm.ts";
import { MAX_REQUEST_BYTES, readBodyCapped } from "../statements-upload/form.ts";
import { HttpError } from "../_shared/http.ts";
import type { Db } from "../_shared/supabase.ts";

Deno.env.delete("SENTRY_DSN");

// ── SRV-03: only contract 422s are permanent ───────────────────────────────

Deno.test("classifyParserResponse: infrastructure 4xx are transient and flagged as config", () => {
  for (const status of [400, 401, 403, 404, 405, 413]) {
    for (const body of [null, { detail: "Not Found" }, { error: { code: "lower case" } }]) {
      const o = classifyParserResponse(status, body);
      assertEquals(o.action, "transient", `status ${status}`);
      assert(o.action === "transient" && o.config, `status ${status} should be config`);
      assertEquals(o.status, status);
    }
  }
});

Deno.test("classifyParserResponse: only a 422 with a known contract code is permanent", () => {
  for (const code of PERMANENT_PARSER_CODES) {
    assertEquals(classifyParserResponse(422, { error: { code, message: "m" } }).action, "permanent", code);
  }
  for (const code of ["PARSE_TIMEOUT", "PDF_TOO_LARGE", "PARSE_OUTPUT_INVALID"]) {
    assert(PERMANENT_PARSER_CODES.has(code));
  }
  const unknown = classifyParserResponse(422, { error: { code: "SOMETHING_NEW", message: "m" } });
  assert(unknown.action === "transient" && unknown.config && unknown.code === "SOMETHING_NEW");
  const bare = classifyParserResponse(422, null);
  assert(bare.action === "transient" && bare.config && bare.code === "PARSER_HTTP_422");
  // A known code on a non-422 (e.g. a proxy echoing JSON) is still not permanent.
  assertEquals(classifyParserResponse(400, { error: { code: "BANK_UNDETECTED" } }).action, "transient");
});

Deno.test("classifyParserResponse: load and server errors are transient, not config", () => {
  for (const status of [408, 429, 500, 502, 503, 504]) {
    const o = classifyParserResponse(status, null);
    assert(o.action === "transient" && !o.config, `status ${status}`);
  }
  const junk200 = classifyParserResponse(200, null);
  assert(junk200.action === "transient" && junk200.config && junk200.code === "PARSER_BAD_RESPONSE");
});

// ── X-06: ingest errors are reported with code + message, never data ───────

Deno.test("isRejectedPayload: data exceptions and check/not-null violations are permanent", () => {
  for (const s of ["22023", "22P02", "22007", "22008", "22003", "22001", "23514", "23502"]) {
    assert(isRejectedPayload(s), s);
  }
  for (const s of ["", "57014", "40001", "23505", "23503", "08006", "P0002", "42501"]) assert(!isRejectedPayload(s), s);
});

Deno.test("sanitizePgMessage keeps object names and drops values", () => {
  const check = 'new row for relation "statements" violates check constraint "statements_check"';
  assertEquals(sanitizePgMessage(check), check);
  assertEquals(pgConstraint(check), "statements_check");
  assertEquals(
    sanitizePgMessage('invalid input syntax for type date: "2025-13-45"'),
    'invalid input syntax for type date: "[Filtered]"',
  );
  assertEquals(
    sanitizePgMessage('invalid input syntax for type numeric: "CARREFOUR 1234"'),
    'invalid input syntax for type numeric: "[Filtered]"',
  );
  assertEquals(
    sanitizePgMessage('null value in column "txn_date" of relation "statement_lines" violates not-null constraint'),
    'null value in column "txn_date" of relation "statement_lines" violates not-null constraint',
  );
  assertEquals(sanitizePgMessage(undefined), "(no message)");
  assertEquals(sanitizePgMessage(""), "(no message)");
});

// ── SRV-04: budget against the Edge wall clock ─────────────────────────────

const timing = (over: Partial<WorkerTiming> = {}): WorkerTiming => ({
  startedAt: 0,
  budgetMs: 50_000,
  wallClockMs: 150_000,
  parserTimeoutMs: 75_000,
  llmTimeoutMs: 60_000,
  ...over,
});

Deno.test("canStart: a parse round never starts unless the parser timeout + ingest still fit", () => {
  const t = timing();
  const need = parseRoundNeedMs(t);
  assertEquals(need, 95_000);
  assert(canStart(t, 0, need));
  assert(canStart(t, 45_000, need)); // 145 - 45 = 100 s left
  assert(!canStart(t, 50_001, need)); // past WORKER_BUDGET_MS
  const longBudget = timing({ budgetMs: 140_000 });
  assert(!canStart(longBudget, 51_000, need), "wall clock must win over a long budget");
  assert(canStart(longBudget, 51_000, llmRoundNeedMs(longBudget)));
  assert(!canStart(longBudget, 81_000, llmRoundNeedMs(longBudget)));
  // Paid plan (400 s): the budget is the only limit.
  assert(canStart(timing({ wallClockMs: 400_000 }), 49_000, need));
});

Deno.test("attempts and backoff", () => {
  const m = (read_ct: number, attempt?: number): QueueMessage => ({
    msg_id: 1,
    read_ct,
    message: attempt === undefined ? { doc_code: "x" } : { doc_code: "x", attempt },
  });
  assertEquals(attemptOf(m(1)), 1);
  assertEquals(attemptOf(m(1, 3)), 4);
  assertEquals(attemptOf(m(2, -5)), 2);
  assertEquals([1, 2, 3, 4, 5, 9].map(backoffSeconds), [60, 300, 900, 1800, 1800, 1800]);
});

// ── processParseMessage with a fake Db and parser ──────────────────────────

type Call = { name: string; args: Record<string, unknown> };
const DOC = "doc_01k4dffqf0fz41nq50eaa1sqh2";

function fakeDb(opts: { ingestError?: { code: string; message: string } } = {}) {
  const calls: Call[] = [];
  const db = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, args });
      if (name === "begin_document_parse") {
        return Promise.resolve({
          data: {
            doc: { storage_path: "p/doc.pdf", original_filename: "x.pdf", bank_code: "ENBD", profile_code: "prf_x" },
            settings: {},
            skip: null,
          },
          error: null,
        });
      }
      if (name === "ingest_parsed_document" && opts.ingestError) {
        return Promise.resolve({ data: null, error: opts.ingestError });
      }
      if (name === "queue_send") return Promise.resolve({ data: 99, error: null });
      return Promise.resolve({ data: null, error: null });
    },
    from(_t: string) {
      return { update: (_v: unknown) => ({ eq: (_c: string, _x: unknown) => Promise.resolve({ error: null }) }) };
    },
    storage: {
      from: (_b: string) => ({
        createSignedUrl: (_p: string, _s: number) =>
          Promise.resolve({
            data: { signedUrl: "https://abc.supabase.co/storage/v1/object/sign/x?token=t" },
            error: null,
          }),
      }),
    },
  };
  return { db: db as unknown as Db, calls };
}

async function withParser(response: () => Response, fn: () => Promise<void>) {
  const realFetch = globalThis.fetch;
  Deno.env.set("PARSER_URL", "https://parser.example");
  Deno.env.set("PARSER_SECRET", "s");
  globalThis.fetch = (() => Promise.resolve(response())) as typeof fetch;
  try {
    await fn();
  } finally {
    globalThis.fetch = realFetch;
  }
}

const msg = (read_ct: number, attempt?: number): QueueMessage => ({
  msg_id: 7,
  read_ct,
  message: attempt ? { doc_code: DOC, attempt } : { doc_code: DOC },
});
const names = (calls: Call[]) => calls.map((c) => c.name);
const failCall = (calls: Call[]) => calls.find((c) => c.name === "fail_document")?.args;

Deno.test("a 404 HTML page from a wrong PARSER_URL is retried with backoff, never failed permanently", async () => {
  const { db, calls } = fakeDb();
  await withParser(() => new Response("<html>Not Found</html>", { status: 404 }), async () => {
    const r = await processParseMessage(db, msg(1));
    assertEquals(r.outcome, "retry");
    assertEquals(r.code, "PARSER_HTTP_404");
  });
  assertEquals(failCall(calls)?.p_permanent, false);
  const send = calls.find((c) => c.name === "queue_send")!.args;
  assertEquals(send.p_delay, 60);
  assertEquals((send.p_message as Record<string, unknown>).attempt, 1);
  assert(names(calls).indexOf("queue_send") < names(calls).indexOf("queue_delete"), "send before delete");
});

Deno.test("transient failures dead-letter after MAX_READS attempts", async () => {
  const { db, calls } = fakeDb();
  await withParser(() => new Response("forbidden", { status: 403 }), async () => {
    const r = await processParseMessage(db, msg(1, MAX_READS - 1));
    assertEquals(r.outcome, "dlq");
  });
  assert(names(calls).includes("queue_to_dlq"));
  assertEquals(failCall(calls)?.p_permanent, true);
});

Deno.test("a contract 422 fails the document permanently", async () => {
  const { db, calls } = fakeDb();
  const body = JSON.stringify({ error: { code: "PARSE_TIMEOUT", message: "too slow" } });
  await withParser(() => new Response(body, { status: 422 }), async () => {
    const r = await processParseMessage(db, msg(1));
    assertEquals(r, { doc_code: DOC, outcome: "failed", code: "PARSE_TIMEOUT" });
  });
  assertEquals(failCall(calls)?.p_permanent, true);
  assert(names(calls).includes("queue_delete"));
});

Deno.test("rejected parser output (23514) is permanent and keeps the constraint message", async () => {
  const { db, calls } = fakeDb({
    ingestError: {
      code: "23514",
      message: 'new row for relation "statements" violates check constraint "statements_check"',
    },
  });
  await withParser(() => Response.json({ contract_version: 1, parser_version: "x", statements: [] }), async () => {
    const r = await processParseMessage(db, msg(1));
    assertEquals(r, { doc_code: DOC, outcome: "failed", code: "INGEST_23514" });
  });
  const f = failCall(calls)!;
  assertEquals(f.p_permanent, true);
  assert(String(f.p_error).includes("statements_check"));
});

Deno.test("card-less multi-account statements (INGEST_22023) are permanent", async () => {
  const { db, calls } = fakeDb({ ingestError: { code: "22023", message: "statement has no card number" } });
  await withParser(() => Response.json({ contract_version: 1, parser_version: "x", statements: [] }), async () => {
    const r = await processParseMessage(db, msg(1));
    assertEquals(r, { doc_code: DOC, outcome: "failed", code: "INGEST_22023" });
  });
  assertEquals(failCall(calls)?.p_permanent, true);
});

Deno.test("ingestWarnings reads only string warnings", () => {
  assertEquals(ingestWarnings({ warnings: ["statement 2026-01-28 skipped", 3, null] }), [
    "statement 2026-01-28 skipped",
  ]);
  assertEquals(ingestWarnings(null), []);
  assertEquals(ingestWarnings({ warnings: "x" }), []);
});

Deno.test("an ingest timeout (57014) is retried", async () => {
  const { db, calls } = fakeDb({
    ingestError: { code: "57014", message: "canceling statement due to statement timeout" },
  });
  await withParser(() => Response.json({ contract_version: 1, parser_version: "x", statements: [] }), async () => {
    const r = await processParseMessage(db, msg(2));
    assertEquals(r, { doc_code: DOC, outcome: "retry", code: "INGEST_57014" });
  });
  assertEquals(calls.find((c) => c.name === "queue_send")!.args.p_delay, 300);
});

// ── sms_fallback: deterministic failures DLQ once; non-transactions are skipped ──

Deno.test("validateTemplateProposal: 'other' without an amount is not applicable", () => {
  const raw = {
    bank_code: "FAB",
    name: "otp",
    sender_pattern: "FAB",
    body_pattern: "OTP .*",
    field_groups: {
      amount: null,
      currency: null,
      last4: null,
      merchant: null,
      date: null,
      time: null,
      available: null,
    },
    date_format: null,
    msg_kind: "other",
    expect: { amount: null, currency: null, last4: null, merchant: null },
  };
  let caught: unknown;
  try {
    validateTemplateProposal(raw, ["FAB"]);
  } catch (e) {
    caught = e;
  }
  assert(caught instanceof LlmNotApplicable);
});

Deno.test("llmErrorReason is short and never carries arbitrary text", () => {
  assertEquals(
    llmErrorReason(new LlmOutputError("field merchant points at a missing capture group")),
    "field merchant points at a missing capture group",
  );
  assertEquals(llmErrorReason(new LlmOutputError('unknown field "<script>x')), "unknown field scriptx");
  assertEquals(llmErrorReason(Object.assign(new Error("x"), { status: 400 })), "http 400");
});

Deno.test("sms_fallback with no banks configured dead-letters once without calling the LLM", async () => {
  const calls: Call[] = [];
  const db = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, args });
      if (name === "worker_sms_context") {
        return Promise.resolve({
          data: { parse_status: "unparsed", sender: "X", body: "secret", banks: null },
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: null });
    },
  } as unknown as Db;
  const r = await processSmsFallback(db, {
    msg_id: 1,
    read_ct: 1,
    message: { sms_code: "sms_01k4db8acd3wgrmddfx4a4k3sc" },
  });
  assertEquals(r, { queue: "sms_fallback", outcome: "dlq", code: "NO_BANKS" });
  const dlq = calls.find((c) => c.name === "queue_to_dlq")!.args;
  assertEquals(dlq.p_reason, "NO_BANKS: no banks configured");
  assert(!JSON.stringify(calls).includes("anthropic"));
});

// ── SRV-06: bounded upload body ────────────────────────────────────────────

Deno.test("readBodyCapped rejects a declared or streamed body over the cap", async () => {
  const small = new Request("http://x", { method: "POST", body: new Uint8Array(10) });
  assertEquals((await readBodyCapped(small, 100)).byteLength, 10);

  const declared = new Request("http://x", {
    method: "POST",
    body: new Uint8Array(10),
    headers: { "content-length": String(MAX_REQUEST_BYTES + 1) },
  });
  const e1 = await assertRejects(() => readBodyCapped(declared), HttpError);
  assertEquals((e1 as HttpError).status, 413);

  let pulled = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(c) {
      pulled++;
      c.enqueue(new Uint8Array(64));
      if (pulled > 1000) c.close();
    },
  });
  const chunked = new Request("http://x", { method: "POST", body: stream });
  const e2 = await assertRejects(() => readBodyCapped(chunked, 1000), HttpError);
  assertEquals((e2 as HttpError).code, "PAYLOAD_TOO_LARGE");
  assert(pulled < 50, `stopped reading early (pulled ${pulled})`);
});
