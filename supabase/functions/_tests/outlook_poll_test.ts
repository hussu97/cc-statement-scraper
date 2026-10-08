// outlook-poll pollMailbox with a fake Db and a fake Graph/OAuth fetch (SRV-11):
// resume from a stored nextLink, per-page cursor saves, 410 restart, deadline, and
// Microsoft refresh-token rotation (SRV-14).

import { assert, assertEquals } from "jsr:@std/assert@1.0.13";
import { pollMailbox } from "../outlook-poll/poll.ts";
import { deltaKey, GRAPH } from "../outlook-poll/graph.ts";
import type { Mailbox } from "../_shared/email_ingest.ts";
import { FakeDb, fakeFetch, type FetchRoute, mergeSyncStateRpc, PDF_BYTES } from "./fake_db.ts";

Deno.env.delete("SENTRY_DSN");
Deno.env.set("MS_OAUTH_CLIENT_ID", "cid");
Deno.env.set("MS_OAUTH_CLIENT_SECRET", "csecret");

const PRF = "prf_01k6zz0000000000000000000b";
const MBX = "mbx_01k6zz0000000000000000000b";
const INBOX_KEY = deltaKey("Inbox");
const RESUME = `${GRAPH}/me/mailFolders/Inbox/messages/delta?$skiptoken=page2`;

function setup(syncState: Record<string, unknown>, opts: { rotateTo?: string; saveFails?: boolean } = {}) {
  const mailbox: Mailbox = {
    mailbox_code: MBX,
    profile_code: PRF,
    provider: "outlook",
    mailbox_email: "me@outlook.test",
    enabled: true,
    sync_state: syncState,
    watch_expires_at: null,
    last_synced_at: null,
  };
  const db = new FakeDb({
    tables: {
      email_mailboxes: [{ ...mailbox }],
      email_routes: [{
        route_code: "rte_o",
        profile_code: PRF,
        mailbox_code: MBX,
        bank_code: "ADCB",
        enabled: true,
        sender_allowlist: [],
        subject_keywords: [],
        attachment_filename_regex: null,
        gmail_label_filter: [],
      }],
      email_events: [],
      documents: [],
    },
    rpcs: {
      worker_mailbox_secret: () => ({ data: "old-refresh", error: null }),
      set_mailbox_secret: () =>
        opts.saveFails ? { data: null, error: { code: "42501", message: "denied" } } : { data: null, error: null },
      merge_mailbox_sync_state: mergeSyncStateRpc,
    },
  });
  const tokenBody = {
    access_token: "at",
    expires_in: 3600,
    ...(opts.rotateTo ? { refresh_token: opts.rotateTo } : {}),
  };
  return { db, mailbox, tokenBody };
}

const state = (db: FakeDb) => db.tables.email_mailboxes[0].sync_state as Record<string, unknown>;

function graphRoute(tokenBody: Record<string, unknown>, over: (url: URL) => Response | null = () => null): FetchRoute {
  return (url) => {
    if (url.host === "login.microsoftonline.com") return Response.json(tokenBody);
    const o = over(url);
    if (o) return o;
    const p = decodeURIComponent(url.pathname);
    if (p.endsWith("/messages/delta")) {
      if (url.searchParams.get("$skiptoken") === "page2") {
        return Response.json({
          value: [{
            id: "msg2",
            hasAttachments: true,
            subject: "Statement",
            from: { emailAddress: { address: "a@b" } },
          }],
          "@odata.deltaLink": `${GRAPH}/me/mailFolders/Inbox/messages/delta?$deltatoken=done`,
        });
      }
      // Any other folder / fresh delta: empty and complete.
      return Response.json({ value: [], "@odata.deltaLink": `${GRAPH}${url.pathname}?$deltatoken=fresh` });
    }
    if (p.endsWith("/messages/msg2/attachments")) {
      return Response.json({
        value: [
          { id: "att1", name: "stmt.pdf", contentType: "application/pdf", size: PDF_BYTES.length },
          { id: "att2", name: "huge.pdf", contentType: "application/pdf", size: 26 * 1024 * 1024 },
        ],
      });
    }
    if (p.endsWith("/attachments/att1")) {
      return Response.json({ contentBytes: btoa(String.fromCharCode(...PDF_BYTES)) });
    }
    return null;
  };
}

Deno.test("outlook-poll resumes from the stored nextLink and saves the deltaLink", async () => {
  const { db, mailbox, tokenBody } = setup({ [INBOX_KEY]: RESUME });
  const f = fakeFetch(graphRoute(tokenBody));
  const r = await pollMailbox(db.asDb(), mailbox, { deadline: Infinity, lookbackDays: 90, fetchFn: f.fetch });
  assertEquals(r.status, "ok");
  assertEquals([r.messages, r.ingested, r.ignored], [1, 1, 1]);
  assertEquals(f.urls.find((u) => u.includes("/Inbox/")), RESUME, "first Inbox call is the stored cursor");
  assert(String(state(db)[INBOX_KEY]).endsWith("$deltatoken=done"));
  assert(!f.urls.some((u) => u.endsWith("/attachments/att2")), "oversized attachment never downloaded");
  assertEquals(db.tables.documents[0].source, "outlook");
  assertEquals(state(db).last_error, null);
  assert(db.tables.email_mailboxes[0].last_synced_at);
});

Deno.test("outlook-poll restarts an expired delta (410) once", async () => {
  const { db, mailbox, tokenBody } = setup({ [INBOX_KEY]: RESUME });
  const f = fakeFetch(
    graphRoute(
      tokenBody,
      (url) => url.searchParams.get("$skiptoken") === "page2" ? new Response("", { status: 410 }) : null,
    ),
  );
  const r = await pollMailbox(db.asDb(), mailbox, { deadline: Infinity, lookbackDays: 30, fetchFn: f.fetch });
  assertEquals(r.status, "ok");
  const inbox = f.urls.filter((u) => u.includes("/Inbox/"));
  assertEquals(inbox.length, 2);
  assert(decodeURIComponent(inbox[1]).includes("receivedDateTime ge"), "restarted with a fresh lookback delta");
  assert(String(state(db)[INBOX_KEY]).endsWith("$deltatoken=fresh"));
});

Deno.test("outlook-poll stops at the deadline and keeps the cursor", async () => {
  const { db, mailbox, tokenBody } = setup({ [INBOX_KEY]: RESUME });
  const f = fakeFetch(graphRoute(tokenBody));
  const r = await pollMailbox(db.asDb(), mailbox, { deadline: 0, now: () => 1, lookbackDays: 90, fetchFn: f.fetch });
  assertEquals(r.status, "budget_exhausted");
  assertEquals(state(db)[INBOX_KEY], RESUME, "cursor untouched");
  assert(!f.urls.some((u) => u.includes("graph.microsoft.com")), "no Graph call after the deadline");
});

Deno.test("Microsoft refresh-token rotation is persisted; a failed save is not fatal (SRV-14)", async () => {
  const ok = setup({}, { rotateTo: "new-refresh" });
  await pollMailbox(ok.db.asDb(), ok.mailbox, {
    deadline: Infinity,
    lookbackDays: 1,
    fetchFn: fakeFetch(graphRoute(ok.tokenBody)).fetch,
  });
  assertEquals(ok.db.rpcCalls("set_mailbox_secret"), [
    { p_mailbox_code: MBX, p_key: "refresh_token", p_value: "new-refresh" },
  ]);

  const same = setup({}, { rotateTo: "old-refresh" });
  await pollMailbox(same.db.asDb(), same.mailbox, {
    deadline: Infinity,
    lookbackDays: 1,
    fetchFn: fakeFetch(graphRoute(same.tokenBody)).fetch,
  });
  assertEquals(same.db.rpcCalls("set_mailbox_secret").length, 0, "an unchanged token is not rewritten");

  const failing = setup({}, { rotateTo: "new-refresh", saveFails: true });
  const r = await pollMailbox(failing.db.asDb(), failing.mailbox, {
    deadline: Infinity,
    lookbackDays: 1,
    fetchFn: fakeFetch(graphRoute(failing.tokenBody)).fetch,
  });
  assertEquals(r.status, "ok", "the poll continues with the access token");
});
