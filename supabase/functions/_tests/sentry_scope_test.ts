// SRV-18: two requests interleaving in one isolate keep their own Sentry scope. Each
// handler tags its scope, yields to the other, then fails; every event must carry only
// its own request's tags. Runs against a fake Sentry ingest server.

import { assertEquals } from "jsr:@std/assert@1.0.13";

const received: string[] = [];
const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen() {} }, async (req) => {
  received.push(await req.text());
  return new Response("{}", { status: 200 });
});
const port = (server.addr as Deno.NetAddr).port;
Deno.env.set("SENTRY_DSN", `http://publickey@127.0.0.1:${port}/1`);
Deno.env.set("SENTRY_ENVIRONMENT", "ci");
Deno.env.set("SENTRY_TRACES_SAMPLE_RATE", "0");

const { withSentry, Sentry, captureMessage, setRequestTag } = await import("../_shared/sentry.ts");

// deno-lint-ignore no-explicit-any
function events(): Record<string, any>[] {
  // deno-lint-ignore no-explicit-any
  const out: Record<string, any>[] = [];
  for (const env of received) {
    const lines = env.split("\n").filter(Boolean);
    for (let i = 1; i < lines.length; i += 2) {
      if (JSON.parse(lines[i]).type === "event") out.push(JSON.parse(lines[i + 1]));
    }
  }
  return out;
}

Deno.test({
  name: "withSentry isolates scopes across interleaved requests",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    // A gate makes the interleaving deterministic: A tags, B tags, then both report.
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    let started = 0;
    const make = (name: string) =>
      withSentry(name, async (req) => {
        const id = req.headers.get("x-req") ?? "";
        setRequestTag("req", id);
        if (++started === 2) release();
        await gate;
        await new Promise((r) => setTimeout(r, id === "a" ? 5 : 0));
        captureMessage(`message from ${id}`, { tags: { doc_code: `doc_${id}` } });
        throw new Error(`boom ${id}`);
      });
    const a = make("worker");
    const b = make("sms-ingest");
    const [ra, rb] = await Promise.all([
      a(new Request("http://x/worker", { method: "POST", headers: { "x-req": "a" } })),
      b(new Request("http://x/sms-ingest", { method: "POST", headers: { "x-req": "b" } })),
    ]);
    assertEquals([ra.status, rb.status], [500, 500]);
    await Sentry.flush(3000);

    const evs = events();
    assertEquals(evs.length, 4, "a message and an exception per request");
    for (const ev of evs) {
      const text = String(ev.message ?? ev.logentry?.message ?? ev.exception?.values?.[0]?.value ?? "");
      const id = text.endsWith("a") ? "a" : "b";
      assertEquals(ev.tags.req, id, `req tag on "${text}"`);
      assertEquals(ev.tags.function, id === "a" ? "worker" : "sms-ingest", `function tag on "${text}"`);
      if (ev.tags.doc_code) assertEquals(ev.tags.doc_code, `doc_${id}`);
    }
    await server.shutdown();
  },
});
