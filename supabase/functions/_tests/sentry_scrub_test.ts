import { assert, assertEquals } from "jsr:@std/assert@1.0.13";
import { scrubBreadcrumb, scrubEvent, scrubString } from "../_shared/sentry.ts";

const SMS = "Purchase of AED 52.25 at CARREFOUR with card ending 3687";
const TOKEN = "ccs_0123456789abcdef0123456789abcdef";

function smsIngestEvent() {
  return {
    message: `failed for Bearer ${TOKEN} at https://x.supabase.co/storage/v1/object/sign/a.pdf?token=abc.def`,
    request: {
      url: "https://x.supabase.co/functions/v1/sms-ingest?profile=prf_1&secret=1",
      query_string: "profile=prf_1",
      data: JSON.stringify({ messages: [{ body: SMS }] }),
      cookies: { sb: "x" },
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        "X-Profile-Key": "hussain",
        "x-cron-secret": "s3cret",
        apikey: "anon-key",
        "content-type": "application/json",
      },
    },
    user: { id: "u1", email: "a@b.c", ip_address: "1.2.3.4" },
    extra: {
      sms_code: "sms_01abc",
      body: SMS,
      nested: { password: "pw", refresh_token: "rt", settings: { FAB_PDF_PASSWORD: "x" }, ok: 1 },
      list: [{ sms: SMS }, "plain"],
    },
    contexts: { parser: { document_url: "https://x/y?token=1", status: 500 } },
    breadcrumbs: [
      { message: `GET https://api/x?access_token=zzz`, data: { url: "https://h/p?sig=1", body: SMS, method: "GET" } },
    ],
    exception: { values: [{ type: "Error", value: `HTTP 500 for Bearer ${TOKEN}`, stacktrace: { frames: [{ vars: { body: SMS } }] } }] },
    tags: { function: "sms-ingest", token: "t" },
  };
}

Deno.test("scrubEvent removes SMS bodies, auth headers, tokens and query strings", () => {
  const original = smsIngestEvent();
  // deno-lint-ignore no-explicit-any
  const e: any = scrubEvent(original as any);
  const serialized = JSON.stringify(e);
  assert(!serialized.includes("CARREFOUR"), "SMS body leaked");
  assert(!serialized.includes(TOKEN), "service token leaked");
  assert(!serialized.includes("s3cret"), "cron secret leaked");
  assert(!serialized.includes("hussain"), "profile key leaked");
  assert(!serialized.includes("anon-key"), "apikey leaked");
  assert(!serialized.includes("a@b.c") && !serialized.includes("1.2.3.4"), "user PII leaked");
  assert(!serialized.includes("token=abc"), "signed URL token leaked");
  assert(!serialized.includes("access_token=zzz") && !serialized.includes("sig=1"), "query string leaked");
  assert(!serialized.includes('"pw"') && !serialized.includes('"rt"'), "password/token field leaked");

  assertEquals(e.request.data, undefined);
  assertEquals(e.request.query_string, undefined);
  assertEquals(e.request.cookies, undefined);
  assertEquals(e.request.url, "https://x.supabase.co/functions/v1/sms-ingest");
  assertEquals(e.request.headers["content-type"], "application/json");
  assertEquals(e.request.headers.Authorization, "[Filtered]");
  assertEquals(e.user, { id: "u1" });
  // Opaque codes survive.
  assertEquals(e.extra.sms_code, "sms_01abc");
  assertEquals(e.extra.nested.ok, 1);
  assertEquals(e.tags.function, "sms-ingest");
  assertEquals(e.contexts.parser.status, 500);
  assertEquals(e.breadcrumbs[0].data.method, "GET");
  assertEquals(e.breadcrumbs[0].data.url, "https://h/p");
  // The input is not mutated.
  assertEquals(original.extra.body, SMS);
});

Deno.test("scrubEvent passes null through and handles minimal events", () => {
  assertEquals(scrubEvent(null), null);
  assertEquals(scrubEvent({ message: "ok" }), { message: "ok" });
});

Deno.test("scrubString filters bearer tokens, service tokens, JWTs and URL queries", () => {
  assertEquals(scrubString("Bearer abc.def"), "Bearer [Filtered]");
  assertEquals(scrubString(`token ${TOKEN} end`), "token [Filtered] end");
  assertEquals(scrubString("jwt eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.sig_x end"), "jwt [Filtered] end");
  assertEquals(scrubString("see https://a.b/c?x=1#f"), "see https://a.b/c?[Filtered]#f");
});

Deno.test("scrubBreadcrumb strips data payloads and URL queries", () => {
  // deno-lint-ignore no-explicit-any
  const b: any = scrubBreadcrumb({ category: "fetch", data: { url: "https://p/parse?x=1", password_candidates: ["a"] } } as any);
  assertEquals(b.data.url, "https://p/parse");
  assertEquals(b.data.password_candidates, "[Filtered]");
});
