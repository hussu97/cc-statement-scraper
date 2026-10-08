// Runs withSentry against a fake Sentry ingest server and checks what actually
// leaves the isolate: the error event arrives tagged, scrubbed, and with the
// incoming trace continued; expected 4xx errors are not reported.

import { assert, assertEquals } from "jsr:@std/assert@1.0.13";

const received: string[] = [];
const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen() {} }, async (req) => {
  received.push(await req.text());
  return new Response("{}", { status: 200 });
});
const port = (server.addr as Deno.NetAddr).port;
Deno.env.set("SENTRY_DSN", `http://publickey@127.0.0.1:${port}/1`);
// "test"/"local" disable Sentry (sentry_local_test.ts); use a non-local name here.
Deno.env.set("SENTRY_ENVIRONMENT", "ci");
Deno.env.set("SENTRY_TRACES_SAMPLE_RATE", "0");

const { withSentry, Sentry } = await import("../_shared/sentry.ts");
const { HttpError } = await import("../_shared/http.ts");

const SMS = "Purchase of AED 52.25 at CARREFOUR card 9208";
const TRACE_ID = "771a43a4192642f0b136d5159a501700";

function events(): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const env of received) {
    const lines = env.split("\n").filter(Boolean);
    for (let i = 1; i < lines.length; i += 2) {
      const header = JSON.parse(lines[i]);
      if (header.type === "event") out.push(JSON.parse(lines[i + 1]));
    }
  }
  return out;
}

Deno.test({
  name: "withSentry reports unhandled errors scrubbed and tagged, skips expected 4xx",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const failing = withSentry("sms-ingest", (req) => {
      Sentry.addBreadcrumb({ message: "ingest", data: { body: SMS } });
      throw new Error(`boom for ${req.headers.get("authorization")}`);
    });
    const res = await failing(
      new Request("http://x/functions/v1/sms-ingest?token=abc", {
        method: "POST",
        headers: {
          Authorization: "Bearer ccs_0123456789abcdef0123456789abcdef",
          "X-Profile-Key": "pk-zq81-secret",
          "sentry-trace": `${TRACE_ID}-1000000000000000-1`,
        },
        body: JSON.stringify({ messages: [{ body: SMS }] }),
      }),
    );
    assertEquals(res.status, 500);
    assertEquals((await res.json()).error.code, "INTERNAL");

    const expected = withSentry("sms-ingest", () => {
      throw new HttpError(422, "INVALID_MESSAGE", "bad");
    });
    assertEquals((await expected(new Request("http://x", { method: "POST" }))).status, 422);

    await Sentry.flush(3000);
    const evs = events();
    assertEquals(evs.length, 1, `expected exactly one event, got ${evs.length}`);
    const ev = evs[0] as Record<string, any>;
    const raw = JSON.stringify(ev);
    assert(!raw.includes("CARREFOUR"), "SMS body leaked");
    assert(!raw.includes("ccs_0123456789abcdef"), "service token leaked");
    assert(!raw.includes("pk-zq81-secret"), "profile key leaked");
    assertEquals(ev.tags.function, "sms-ingest");
    assertEquals(ev.tags.service, "edge");
    assertEquals(ev.environment, "ci");
    assertEquals(ev.contexts?.trace?.trace_id, TRACE_ID);
    await server.shutdown();
  },
});
