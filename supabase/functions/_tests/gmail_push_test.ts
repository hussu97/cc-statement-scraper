// gmail-push processMailbox with a fake Db and a fake Gmail/OAuth fetch (SRV-05, SRV-07,
// SRV-11, SRV-14, SRV-19). Sentry is off (no DSN), so nothing is sent.

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1.0.13";
import { isPermanentMailboxError, MAX_BACKFILL_PAGES, processMailbox } from "../gmail-push/process.ts";
import { type Mailbox, mailboxErrorCode } from "../_shared/email_ingest.ts";
import { HttpError } from "../_shared/http.ts";
import { ProviderHttpError } from "../_shared/provider.ts";
import { b64url, FakeDb, fakeFetch, type FetchRoute, PDF_BYTES, saveSyncStateRpc } from "./fake_db.ts";

Deno.env.delete("SENTRY_DSN");
Deno.env.set("GMAIL_OAUTH_CLIENT_ID", "cid");
Deno.env.set("GMAIL_OAUTH_CLIENT_SECRET", "csecret");

const PRF = "prf_01k6zz0000000000000000000a";
const MBX = "mbx_01k6zz0000000000000000000a";

function setup(syncState: Record<string, unknown> = { gmail_history_id: "100" }) {
  const mailbox: Mailbox = {
    mailbox_code: MBX,
    profile_code: PRF,
    provider: "gmail",
    mailbox_email: "me@gmail.test",
    enabled: true,
    sync_state: syncState,
    watch_expires_at: null,
    last_synced_at: "2026-10-01T00:00:00.000Z",
  };
  const db = new FakeDb({
    tables: {
      email_mailboxes: [{ ...mailbox }],
      email_routes: [{
        route_code: "rte_1",
        profile_code: PRF,
        mailbox_code: MBX,
        bank_code: "FAB",
        enabled: true,
        sender_allowlist: ["alerts@bank.test"],
        subject_keywords: [],
        attachment_filename_regex: null,
        gmail_label_filter: [],
      }],
      email_events: [],
      documents: [],
    },
    rpcs: {
      worker_mailbox_secret: () => ({ data: "refresh-token", error: null }),
      save_mailbox_sync_state: saveSyncStateRpc,
    },
  });
  return { db, mailbox };
}

const cursor = (db: FakeDb) => (db.tables.email_mailboxes[0].sync_state as Record<string, unknown>).gmail_history_id;
const savedCursors = (db: FakeDb) =>
  db.rpcCalls("save_mailbox_sync_state").map((a) => (a.p_patch as Record<string, unknown>).gmail_history_id);

function message(id: string, withPdf: boolean, size = PDF_BYTES.length) {
  return {
    id,
    labelIds: ["INBOX"],
    payload: {
      headers: [{ name: "From", value: "Bank <alerts@bank.test>" }, { name: "Subject", value: "Statement" }],
      parts: withPdf
        ? [{ partId: "1", filename: "stmt.pdf", mimeType: "application/pdf", body: { attachmentId: `A-${id}`, size } }]
        : [],
    },
  };
}

/** Token endpoint + two history pages (m1 with a PDF, m2 without) + message/attachment routes. */
function gmailRoute(over: Partial<Record<string, (url: URL) => Response | null>> = {}): FetchRoute {
  return (url) => {
    if (url.host === "oauth2.googleapis.com") return Response.json({ access_token: "at", expires_in: 3600 });
    const path = url.pathname.replace("/gmail/v1/users/me", "");
    const custom = over[path.split("/")[1] ?? ""];
    if (custom) return custom(url);
    if (path === "/history") {
      return url.searchParams.get("pageToken") === "p2"
        ? Response.json({ history: [{ id: "150", messagesAdded: [{ message: { id: "m2" } }] }], historyId: "200" })
        : Response.json({
          history: [{ id: "110", messagesAdded: [{ message: { id: "m1" } }] }],
          nextPageToken: "p2",
          historyId: "200",
        });
    }
    if (path === "/messages/m1") return Response.json(message("m1", true));
    if (path === "/messages/m2") return Response.json(message("m2", false));
    if (path.startsWith("/messages/m1/attachments/")) return Response.json({ data: b64url(PDF_BYTES) });
    return null;
  };
}

Deno.test("gmail-push: first push only stores the cursor", async () => {
  const { db, mailbox } = setup({});
  const f = fakeFetch(gmailRoute());
  const r = await processMailbox(db.asDb(), mailbox, "77", { deadline: Infinity, fetchFn: f.fetch });
  assertEquals(r.status, "cursor_initialised");
  assertEquals(cursor(db), "77");
  assertEquals(f.urls.length, 0, "no Gmail call before a cursor exists");
});

Deno.test("gmail-push: pages advance the cursor one by one, filtered to the watch label", async () => {
  const { db, mailbox } = setup();
  const f = fakeFetch(gmailRoute());
  const r = await processMailbox(db.asDb(), mailbox, "180", { deadline: Infinity, fetchFn: f.fetch });
  assertEquals(r.status, "ok");
  assertEquals([r.messages, r.ingested, r.seen], [2, 1, 0]);
  // Saved after page 1 (110), page 2 (150), then the mailbox's history id at the end.
  assertEquals(savedCursors(db), ["110", "150", "200"]);
  assertEquals(cursor(db), "200");
  const history = f.urls.filter((u) => u.includes("/history"));
  assert(history.every((u) => new URL(u).searchParams.get("labelId") === "INBOX"), "labelId filter");
  assertEquals(db.tables.documents.length, 1);
  assertEquals(db.tables.documents[0].source, "gmail");
  assertEquals(db.tables.documents[0].bank_code, "FAB");
  assertEquals(db.tables.email_events[0].status, "ingested");
  assertEquals((db.tables.email_mailboxes[0].sync_state as Record<string, unknown>).last_error, null);

  // Redelivery is idempotent: the attachment is "seen" and never downloaded again.
  const before = f.urls.length;
  const again = await processMailbox(db.asDb(), mailbox, "180", { deadline: Infinity, fetchFn: f.fetch });
  assertEquals([again.ingested, again.seen], [0, 1]);
  assert(!f.urls.slice(before).some((u) => u.includes("/attachments/")));
});

Deno.test("gmail-push: the deadline stops between pages and keeps the progress", async () => {
  const { db, mailbox } = setup();
  let clock = 0;
  const f = fakeFetch(gmailRoute({
    messages: (url) => {
      if (url.pathname.includes("/attachments/")) clock = 10; // time passes while downloading
      return gmailRoute()(url, undefined) as Response;
    },
  }));
  const r = await processMailbox(db.asDb(), mailbox, "180", { deadline: 5, now: () => clock, fetchFn: f.fetch });
  assertEquals(r.status, "budget_exhausted");
  assertEquals(cursor(db), "110", "page 1 is saved; page 2 is left for the redelivery");
  assert(!f.urls.some((u) => u.includes("pageToken=p2")));
});

Deno.test("gmail-push: a 404 cursor reset backfills since the last sync, then resets", async () => {
  const { db, mailbox } = setup();
  const f = fakeFetch(gmailRoute({
    history: () => new Response("gone", { status: 404 }),
    profile: () => Response.json({ historyId: "500" }),
    messages: (url) =>
      url.pathname.endsWith("/messages")
        ? Response.json({ messages: [{ id: "m1" }] })
        : gmailRoute()(url, undefined) as Response,
  }));
  const r = await processMailbox(db.asDb(), mailbox, "450", { deadline: Infinity, fetchFn: f.fetch });
  assertEquals(r.status, "cursor_reset");
  assertEquals(r.backfill_complete, true);
  assertEquals(r.ingested, 1);
  assertEquals(cursor(db), "500");
  const list = new URL(f.urls.find((u) => new URL(u).pathname.endsWith("/messages"))!);
  // last_synced_at 2026-10-01 minus one day of slack.
  assertEquals(list.searchParams.get("q"), `has:attachment after:${Date.parse("2026-09-30T00:00:00Z") / 1000}`);
  assertEquals(list.searchParams.getAll("labelIds"), ["INBOX"]);
  assert((db.tables.email_mailboxes[0].sync_state as Record<string, unknown>).cursor_reset_at);
});

Deno.test("gmail-push: the backfill is bounded", async () => {
  const { db, mailbox } = setup();
  let pages = 0;
  const f = fakeFetch(gmailRoute({
    history: () => new Response("gone", { status: 404 }),
    profile: () => Response.json({ historyId: "500" }),
    messages: (url) => {
      if (!url.pathname.endsWith("/messages")) return gmailRoute()(url, undefined) as Response;
      pages++;
      return Response.json({ messages: [{ id: "m2" }], nextPageToken: `p${pages}` });
    },
  }));
  const r = await processMailbox(db.asDb(), mailbox, null, { deadline: Infinity, fetchFn: f.fetch });
  assertEquals(r.status, "cursor_reset");
  assertEquals(r.backfill_complete, false);
  assertEquals(pages, MAX_BACKFILL_PAGES);
  assertEquals(cursor(db), "500", "without a pushed id the profile's history id is used");
});

Deno.test("gmail-push: attachments over 25 MB are ignored without downloading (SRV-07)", async () => {
  const { db, mailbox } = setup();
  const f = fakeFetch(gmailRoute({
    messages: (url) =>
      url.pathname.endsWith("/messages/m1")
        ? Response.json(message("m1", true, 30 * 1024 * 1024))
        : gmailRoute()(url, undefined) as Response,
  }));
  const r = await processMailbox(db.asDb(), mailbox, null, { deadline: Infinity, fetchFn: f.fetch });
  assertEquals([r.ingested, r.ignored], [0, 1]);
  assertEquals(db.tables.email_events[0].detail, "FILE_TOO_LARGE");
  assert(!f.urls.some((u) => u.includes("/attachments/")));
});

Deno.test("gmail-push: a revoked grant is a permanent error with an opaque code (SRV-14, SRV-19)", async () => {
  const { db, mailbox } = setup();
  const f = fakeFetch((url) =>
    url.host === "oauth2.googleapis.com" ? Response.json({ error: "invalid_grant" }, { status: 400 }) : null
  );
  const e = await assertRejects(() =>
    processMailbox(db.asDb(), mailbox, "1", { deadline: Infinity, fetchFn: f.fetch })
  );
  assert(isPermanentMailboxError(e));
  assertEquals(mailboxErrorCode(e, "gmail"), "TOKEN_REFRESH_FAILED:invalid_grant");
});

Deno.test("isPermanentMailboxError separates redeliverable failures", () => {
  const cases: [unknown, boolean][] = [
    [new HttpError(500, "MISCONFIGURED", "GMAIL_OAUTH_CLIENT_ID not set"), true],
    [new HttpError(409, "MAILBOX_NOT_CONNECTED", "x"), true],
    [new HttpError(502, "TOKEN_REFRESH_FAILED", "gmail token refresh failed: HTTP 400 invalid_grant"), true],
    [new HttpError(502, "TOKEN_REFRESH_FAILED", "gmail token refresh failed: HTTP 503 "), false],
    [new HttpError(500, "SECRET_READ_FAILED", "x"), false],
    [new ProviderHttpError(401, "Gmail API HTTP 401"), true],
    [new ProviderHttpError(429, "Gmail API HTTP 429"), false],
    [new ProviderHttpError(503, "Gmail API HTTP 503"), false],
    [new TypeError("network"), false],
  ];
  for (const [e, want] of cases) assertEquals(isPermanentMailboxError(e), want, String(e));
  assertEquals(mailboxErrorCode(new ProviderHttpError(503, "x"), "gmail"), "GMAIL_503");
  assertEquals(mailboxErrorCode(new ProviderHttpError(410, "x"), "outlook"), "GRAPH_410");
  assertEquals(mailboxErrorCode(new Error("boom with me@gmail.test"), "gmail"), "ERROR");
});
