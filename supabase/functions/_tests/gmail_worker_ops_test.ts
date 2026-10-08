import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1.0.13";
import { createLocalJWKSet } from "../_shared/deps.ts";
import { exportJWK, generateKeyPair, SignJWT } from "npm:jose@6.2.12";
import { HttpError } from "../_shared/http.ts";
import {
  base64UrlToBytes,
  decodePubSubEnvelope,
  type GmailMessage,
  headerMap,
  historyMessageIds,
  pdfAttachmentStubs,
  verifyPushToken,
} from "../_shared/gmail.ts";
import { classifyParserResponse, rewriteOrigin } from "../worker/parse_document.ts";
import { evaluateHealth } from "../ops-monitor/health.ts";
import { deltaKey, initialDeltaUrl, pdfAttachments, storedCursor } from "../outlook-poll/graph.ts";

// ── Pub/Sub OIDC ────────────────────────────────────────────────────────────
const AUD = "https://x.supabase.co/functions/v1/gmail-push";
const SA = "gmail-push@proj.iam.gserviceaccount.com";
const { publicKey, privateKey } = await generateKeyPair("RS256");
const jwk = { ...(await exportJWK(publicKey)), kid: "k1", alg: "RS256" };
const jwks = createLocalJWKSet({ keys: [jwk] });
const sign = (claims: Record<string, unknown>, aud = AUD, iss = "https://accounts.google.com") =>
  new SignJWT(claims).setProtectedHeader({ alg: "RS256", kid: "k1" }).setIssuer(iss).setAudience(aud)
    .setIssuedAt().setExpirationTime("5m").sign(privateKey);

Deno.test("verifyPushToken accepts a Google-shaped token for the right audience and account", async () => {
  await verifyPushToken(await sign({ email: SA, email_verified: true }), { audience: AUD, email: SA, jwks });
});

Deno.test("verifyPushToken rejects wrong audience, account, issuer, unverified email and missing token", async () => {
  const opts = { audience: AUD, email: SA, jwks };
  const s401 = async (t: string | null) =>
    assertEquals((await assertRejects(() => verifyPushToken(t, opts), HttpError) as HttpError).status, 401);
  await s401(null);
  await s401(await sign({ email: SA, email_verified: true }, "https://other"));
  await s401(await sign({ email: SA, email_verified: true }, AUD, "https://evil.example"));
  await s401("not.a.jwt");
  const wrongSa = await sign({ email: "other@proj.iam.gserviceaccount.com", email_verified: true });
  assertEquals((await assertRejects(() => verifyPushToken(wrongSa, opts), HttpError) as HttpError).status, 403);
  const unverified = await sign({ email: SA, email_verified: false });
  assertEquals((await assertRejects(() => verifyPushToken(unverified, opts), HttpError) as HttpError).status, 403);
  const misconfigured = await assertRejects(() => verifyPushToken("x", { audience: "", email: SA, jwks }), HttpError);
  assertEquals((misconfigured as HttpError).status, 500);
});

// ── Gmail envelope / message helpers ────────────────────────────────────────
Deno.test("decodePubSubEnvelope", () => {
  const data = btoa(JSON.stringify({ emailAddress: "me@gmail.com", historyId: 12345 }));
  assertEquals(decodePubSubEnvelope({ message: { data } }), { emailAddress: "me@gmail.com", historyId: "12345" });
  assertEquals(decodePubSubEnvelope({ message: { attributes: { emailAddress: "a@b" } } }), { emailAddress: "a@b", historyId: null });
  assertThrows(() => decodePubSubEnvelope({}), HttpError);
  assertThrows(() => decodePubSubEnvelope({ message: { data: "!!!" } }), HttpError);
  assertThrows(() => decodePubSubEnvelope({ message: { data: btoa("{}") } }), HttpError);
});

Deno.test("pdfAttachmentStubs walks nested parts and keys by partId", () => {
  const msg: GmailMessage = {
    id: "m1",
    payload: {
      headers: [{ name: "From", value: "Bank <s@bank.ae>" }, { name: "Subject", value: "Statement" }],
      parts: [
        { partId: "0", mimeType: "text/plain", body: { size: 3 } },
        {
          partId: "1",
          mimeType: "multipart/mixed",
          parts: [
            { partId: "1.1", filename: "Statement.PDF", mimeType: "application/octet-stream", body: { attachmentId: "AAA" } },
            { partId: "1.2", filename: "", mimeType: "application/pdf", body: { attachmentId: "BBB" } },
            { partId: "1.3", filename: "logo.png", mimeType: "image/png", body: { attachmentId: "CCC" } },
          ],
        },
      ],
    },
  };
  assertEquals(pdfAttachmentStubs(msg), [
    { attachmentId: "AAA", key: "part:1.1", filename: "Statement.PDF" },
    { attachmentId: "BBB", key: "part:1.2", filename: "statement.pdf" },
  ]);
  assertEquals(headerMap(msg).subject, "Statement");
});

Deno.test("historyMessageIds dedupes", () => {
  const ids = historyMessageIds({
    history: [{ messagesAdded: [{ message: { id: "a" } }, { message: { id: "b" } }] }, { messagesAdded: [{ message: { id: "a" } }] }],
  });
  assertEquals(ids, ["a", "b"]);
});

Deno.test("base64UrlToBytes handles url-safe alphabet without padding", () => {
  assertEquals(new TextDecoder().decode(base64UrlToBytes("JVBERi0_Pz8")), "%PDF-???");
});

// ── worker ──────────────────────────────────────────────────────────────────
Deno.test("classifyParserResponse follows contract parse-v1", () => {
  assertEquals(classifyParserResponse(200, { contract_version: 1, statements: [] }).action, "ingest");
  assertEquals(classifyParserResponse(200, { contract_version: 2 }).action, "transient");
  const d = classifyParserResponse(422, { error: { code: "PDF_DECRYPT_FAILED", message: "bad password" } });
  assertEquals(d, { action: "permanent", code: "PDF_DECRYPT_FAILED", message: "bad password", status: 422 });
  assertEquals(classifyParserResponse(502, { error: { code: "DOWNLOAD_FAILED" } }).action, "transient");
  assertEquals(classifyParserResponse(500, null), {
    action: "transient",
    code: "PARSER_HTTP_500",
    message: "parser returned HTTP 500",
    status: 500,
    config: false,
  });
  assertEquals(classifyParserResponse(401, { error: { code: "UNAUTHORIZED" } }).action, "transient");
  assertEquals(classifyParserResponse(429, null).action, "transient");
});

Deno.test("rewriteOrigin swaps only the origin of signed URLs", () => {
  const u = "http://kong:8000/storage/v1/object/sign/statements/prf/doc.pdf?token=abc";
  assertEquals(rewriteOrigin(u, undefined), u);
  assertEquals(
    rewriteOrigin(u, "http://127.0.0.1:54321"),
    "http://127.0.0.1:54321/storage/v1/object/sign/statements/prf/doc.pdf?token=abc",
  );
});

// ── outlook ─────────────────────────────────────────────────────────────────
Deno.test("outlook cursors honour the legacy sync_state keys", () => {
  const legacy = "https://graph.microsoft.com/v1.0/me/mailFolders/Inbox/messages/delta?$deltatoken=x";
  assertEquals(deltaKey("DeletedItems"), "microsoft_delta_link_deleteditems");
  assertEquals(storedCursor({ microsoft_delta_link: legacy }, "Inbox"), legacy);
  assertEquals(storedCursor({ microsoft_delta_link: legacy }, "Archive"), null);
  assertEquals(storedCursor({ microsoft_delta_link_inbox: "https://evil/x" }, "Inbox"), null);
  const init = initialDeltaUrl("Inbox", 90, new Date("2026-10-08T00:00:00Z"));
  assert(init.startsWith("https://graph.microsoft.com/v1.0/me/mailFolders/Inbox/messages/delta?"));
  assert(decodeURIComponent(init).includes("receivedDateTime ge 2026-07-10T00:00:00Z"));
  assertEquals(
    pdfAttachments([
      { id: "1", name: "s.pdf", contentType: "application/pdf" },
      { id: "2", name: "s.pdf", isInline: true },
      { id: "3", name: "x.png", contentType: "image/png" },
      { id: "4", name: "S.PDF", contentType: "application/octet-stream" },
    ]).map((a) => a.id),
    ["1", "4"],
  );
});

// ── ops-monitor ─────────────────────────────────────────────────────────────
Deno.test("evaluateHealth raises one issue per problem type", () => {
  const t = { smsUnparsed24h: 5, openReviews: 50 };
  assertEquals(
    evaluateHealth({
      queues: { parse_document: { depth: 3, oldest_age_s: 10 }, parse_document_dlq: { depth: 0, oldest_age_s: null } },
      cron_failures_15m: [],
      documents_failed_24h: 0,
      documents_stuck: 0,
      sms_unparsed_24h: 5,
      recon_failed: 0,
      open_reviews: 3,
    }, t),
    [],
  );
  const issues = evaluateHealth({
    queues: { sms_fallback_dlq: { depth: 2, oldest_age_s: 60 }, parse_document_dlq: { depth: 1, oldest_age_s: 5 } },
    cron_failures_15m: [{ job: "ledger-worker-kick", message: "boom" }, { job: "ledger-worker-kick", message: "boom" }],
    documents_failed_24h: 1,
    documents_stuck: 2,
    sms_unparsed_24h: 6,
    recon_failed: 1,
    open_reviews: 51,
  }, t);
  assertEquals(issues.map((i) => i.issue).sort(), [
    "cron_failures",
    "dlq:parse_document_dlq",
    "dlq:sms_fallback_dlq",
    "documents_failed",
    "documents_stuck",
    "recon_failed",
    "review_backlog",
    "sms_unparsed",
  ]);
  const cron = issues.find((i) => i.issue === "cron_failures")!;
  assertEquals(cron.extra, { jobs: ["ledger-worker-kick"] }); // no return_message
  assertEquals(cron.level, "error");
});
