// Sentry must stay off locally even when a DSN is configured: nothing reaches the
// ingest server when SENTRY_ENVIRONMENT is local/development/test or unset.

import { assert, assertEquals } from "jsr:@std/assert@1.0.13";

const received: string[] = [];
const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen() {} }, async (req) => {
  received.push(await req.text());
  return new Response("{}", { status: 200 });
});
const port = (server.addr as Deno.NetAddr).port;
Deno.env.set("SENTRY_DSN", `http://publickey@127.0.0.1:${port}/1`);
Deno.env.set("SENTRY_ENVIRONMENT", "local");

const { captureException, captureMessage, sentryActive, sentryEnabled, sentryEnvironment, withSentry } = await import(
  "../_shared/sentry.ts"
);

Deno.test("sentryActive: only non-local environments with a DSN report", () => {
  const dsn = "https://k@o0.ingest.invalid/1";
  for (const env of [undefined, "", "local", "LOCAL", " development ", "test"]) {
    assertEquals(sentryActive(env, dsn), false, `env=${env}`);
  }
  assertEquals(sentryActive("production", dsn), true);
  assertEquals(sentryActive("staging", dsn), true);
  assertEquals(sentryActive("production", ""), false);
  assertEquals(sentryActive("production", undefined), false);
});

Deno.test("sentryEnvironment defaults to local", () => {
  const prev = Deno.env.get("SENTRY_ENVIRONMENT");
  Deno.env.delete("SENTRY_ENVIRONMENT");
  try {
    assertEquals(sentryEnvironment(), "local");
  } finally {
    if (prev !== undefined) Deno.env.set("SENTRY_ENVIRONMENT", prev);
  }
});

Deno.test({
  name: "local environment with a DSN sends nothing",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    assertEquals(sentryEnabled(), false);
    captureMessage("should not be sent", { level: "error" });
    captureException(new Error("should not be sent"));
    const res = await withSentry("worker", () => {
      throw new Error("boom");
    })(new Request("http://x/functions/v1/worker", { method: "POST" }));
    assertEquals(res.status, 500);
    await new Promise((r) => setTimeout(r, 300));
    assert(received.length === 0, `expected no Sentry traffic, got ${received.length} envelopes`);
    await server.shutdown();
  },
});
