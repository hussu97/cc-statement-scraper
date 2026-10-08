import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1.0.13";
import { errorResponse, HttpError, isExpected, pgErrorToHttp } from "../_shared/http.ts";
import { bearerToken, isServiceToken, requireCron, timingSafeEqual } from "../_shared/auth.ts";
import { buildRefreshRequest } from "../_shared/oauth.ts";

Deno.test("Postgres SQLSTATEs map to HTTP statuses", () => {
  assertEquals(pgErrorToHttp({ code: "42501", message: "not an owner" }).status, 403);
  assertEquals(pgErrorToHttp({ code: "28000", message: "bad token" }).status, 401);
  assertEquals(pgErrorToHttp({ code: "P0002", message: "unknown" }).status, 404);
  assertEquals(pgErrorToHttp({ code: "22023", message: "bad param" }).status, 422);
  assertEquals(pgErrorToHttp({ code: "22P02", message: "bad uuid" }).status, 422);
  assertEquals(pgErrorToHttp({ code: "23505", message: "dup" }).status, 409);
  const unknown = pgErrorToHttp({ code: "XX000", message: "internal detail" }, "db failed");
  assertEquals(unknown.status, 500);
  assertEquals(unknown.message, "db failed"); // internal messages are not exposed
  assertEquals(pgErrorToHttp(null).status, 500);
});

Deno.test("mapped errors keep the RPC message for 4xx", () => {
  const e = pgErrorToHttp({ code: "42501", message: "not a owner of profile prf_x" });
  assertEquals(e.message, "not a owner of profile prf_x");
  assertEquals(e.code, "FORBIDDEN");
});

Deno.test("errorResponse renders HttpError and hides unknown errors", async () => {
  const r1 = errorResponse(new HttpError(422, "NOT_A_PDF", "x is not a PDF"));
  assertEquals(r1.status, 422);
  assertEquals(await r1.json(), { error: { code: "NOT_A_PDF", message: "x is not a PDF" } });
  const r2 = errorResponse(new Error("secret internals"));
  assertEquals(r2.status, 500);
  assertEquals((await r2.json()).error.message, "internal error");
  assert(isExpected(new HttpError(404, "N", "n")));
  assert(!isExpected(new HttpError(502, "N", "n")));
  assert(!isExpected(new Error("x")));
});

Deno.test("bearer parsing and token kind", () => {
  const req = new Request("http://x", { headers: { authorization: "Bearer  ccs_abc " } });
  assertEquals(bearerToken(req), "ccs_abc");
  assertEquals(bearerToken(new Request("http://x")), null);
  assert(isServiceToken("ccs_abc"));
  assert(!isServiceToken("eyJhbGciOi.x.y"));
});

Deno.test("timingSafeEqual", async () => {
  assert(await timingSafeEqual("abc", "abc"));
  assert(!(await timingSafeEqual("abc", "abd")));
  assert(!(await timingSafeEqual("abc", "abcd")));
  assert(!(await timingSafeEqual("", "x")));
});

Deno.test("requireCron accepts only the configured secret and fails closed", async () => {
  const mk = (h?: string) => new Request("http://x", { method: "POST", headers: h ? { "x-cron-secret": h } : {} });
  await requireCron(mk("s3"), "s3");
  await assertRejects(() => requireCron(mk("nope"), "s3"), HttpError, "invalid cron secret");
  await assertRejects(() => requireCron(mk(), "s3"), HttpError);
  const err = await assertRejects(() => requireCron(mk("s3"), ""), HttpError);
  assertEquals((err as HttpError).status, 500);
});

Deno.test("OAuth refresh requests match the legacy provider contracts", () => {
  const g = buildRefreshRequest("gmail", "cid", "csec", "rt");
  assertEquals(g.url, "https://oauth2.googleapis.com/token");
  assertEquals(g.body.get("grant_type"), "refresh_token");
  assertEquals(g.body.get("scope"), null);
  const m = buildRefreshRequest("outlook", "cid", "csec", "rt");
  assertEquals(m.url, "https://login.microsoftonline.com/consumers/oauth2/v2.0/token");
  assertEquals(m.body.get("scope"), "offline_access https://graph.microsoft.com/Mail.Read");
  assertEquals(m.body.get("refresh_token"), "rt");
});
