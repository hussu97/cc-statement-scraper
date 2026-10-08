// storeDocument / ingestAttachment / saveSyncState / worker staleness with a fake Db
// (SRV-11, SRV-15, SRV-20, SRV-23), and the SRV-18 hygiene fixes.

import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1.0.13";
import { prepareDocument, storeDocument } from "../_shared/documents.ts";
import { ingestAttachment, type Mailbox, saveSyncState } from "../_shared/email_ingest.ts";
import { HttpError, pgErrorToHttp } from "../_shared/http.ts";
import { scrubEvent, scrubString } from "../_shared/sentry.ts";
import { processParseMessage } from "../worker/parse_document.ts";
import { FakeDb, PDF_BYTES, saveSyncStateRpc } from "./fake_db.ts";

Deno.env.delete("SENTRY_DSN");

const PRF = "prf_01k6zz0000000000000000000c";

const prepared = () => prepareDocument(PDF_BYTES, "../x/Statement.pdf");

Deno.test("prepareDocument validates once and sanitises the name", async () => {
  const d = await prepared();
  assertEquals(d.filename, "Statement.pdf");
  assertEquals(d.sha256.length, 64);
  const e = await assertRejects(() => prepareDocument(new TextEncoder().encode("nope"), "a.pdf"), HttpError);
  assertEquals((e as HttpError).code, "NOT_A_PDF");
});

Deno.test("storeDocument uploads before inserting, then dedupes by sha256", async () => {
  const db = new FakeDb({ tables: { documents: [] } });
  const document = await prepared();
  const r = await storeDocument(db.asDb(), { profileCode: PRF, document, source: "upload" });
  assertEquals([r.status, r.parse_status], ["queued", "queued"]);
  const kinds = db.calls.filter((c) => c.kind === "upload" || c.kind === "insert").map((c) => c.kind);
  assertEquals(kinds, ["upload", "insert"], "the object exists before the row (the INSERT trigger enqueues)");
  assert(db.objects.has(`${PRF}/${r.doc_code}.pdf`));

  const dup = await storeDocument(db.asDb(), { profileCode: PRF, document, source: "upload" });
  assertEquals(dup, { status: "duplicate", doc_code: r.doc_code, sha256: document.sha256, parse_status: "queued" });
  assertEquals(db.calls.filter((c) => c.kind === "upload").length, 1);
});

Deno.test("storeDocument: a lost insert race (23505) answers duplicate and removes the orphan object", async () => {
  const db = new FakeDb({ tables: { documents: [] } });
  const document = await prepared();
  db.insertError.documents = (_row, d) => {
    // A concurrent upload of the same file won between our lookup and our insert.
    d.tables.documents.push({
      doc_code: "doc_winner",
      profile_code: PRF,
      sha256: document.sha256,
      parse_status: "parsing",
    });
    return { code: "23505", message: 'duplicate key value violates unique constraint "documents_sha"' };
  };
  const r = await storeDocument(db.asDb(), { profileCode: PRF, document, source: "gmail" });
  assertEquals([r.status, r.doc_code, r.parse_status], ["duplicate", "doc_winner", "parsing"]);
  assertEquals(db.objects.size, 0, "our uploaded object was removed");
});

Deno.test("storeDocument: any other insert failure removes the object and throws a fixed message", async () => {
  const db = new FakeDb({ tables: { documents: [] } });
  db.insertError.documents = () => ({
    code: "23503",
    message: 'insert violates foreign key constraint "documents_bank_fk"',
  });
  const e = await assertRejects(
    async () => await storeDocument(db.asDb(), { profileCode: PRF, document: await prepared(), source: "upload" }),
    HttpError,
  );
  assertEquals(e.status, 422);
  assert(!e.message.includes("documents_bank_fk"), "no constraint names to clients (SRV-18)");
  assertEquals(db.objects.size, 0);

  const up = new FakeDb({ tables: { documents: [] } });
  up.uploadError = { code: "500", message: "storage down" };
  const e2 = await assertRejects(
    async () => await storeDocument(up.asDb(), { profileCode: PRF, document: await prepared(), source: "upload" }),
    HttpError,
  );
  assertEquals([e2.status, e2.code], [502, "STORAGE_UPLOAD_FAILED"]);
  assertEquals(up.tables.documents.length, 0);
});

Deno.test("storeDocument: re-sending a failed document resubmits it (SRV-20)", async () => {
  const document = await prepared();
  const failedDoc = () => ({
    doc_code: "doc_failed",
    profile_code: PRF,
    sha256: document.sha256,
    parse_status: "failed",
  });
  const resubmit = { doc_code: "doc_failed", parse_status: "queued", requeued: true };

  const db = new FakeDb({
    tables: { documents: [failedDoc()] },
    rpcs: { resubmit_document: () => ({ data: resubmit, error: null }) },
  });
  const r = await storeDocument(db.asDb(), { profileCode: PRF, document, source: "scraper" });
  assertEquals([r.status, r.parse_status, r.requeued], ["duplicate", "queued", true]);
  assertEquals(db.rpcCalls("resubmit_document"), [{ p_profile_code: PRF, p_doc_code: "doc_failed" }]);

  // The RPC found it no longer failed (a concurrent requeue): plain duplicate, its status.
  const raced = new FakeDb({
    tables: { documents: [failedDoc()] },
    rpcs: {
      resubmit_document: () => ({
        data: { doc_code: "doc_failed", parse_status: "parsing", requeued: false },
        error: null,
      }),
    },
  });
  const r1 = await storeDocument(raced.asDb(), { profileCode: PRF, document, source: "scraper" });
  assertEquals([r1.status, r1.parse_status, r1.requeued], ["duplicate", "parsing", undefined]);

  // A failed resubmit still answers duplicate (the upload itself is fine).
  const broken = new FakeDb({
    tables: { documents: [failedDoc()] },
    rpcs: { resubmit_document: () => ({ data: null, error: { code: "P0002", message: "x" } }) },
  });
  const r2 = await storeDocument(broken.asDb(), { profileCode: PRF, document, source: "scraper" });
  assertEquals([r2.status, r2.parse_status, r2.requeued], ["duplicate", "failed", undefined]);

  // Parsed duplicates are left alone.
  const parsed = new FakeDb({ tables: { documents: [{ ...failedDoc(), parse_status: "parsed" }] } });
  await storeDocument(parsed.asDb(), { profileCode: PRF, document, source: "scraper" });
  assertEquals(parsed.rpcCalls("resubmit_document").length, 0);
});

const mailbox = (): Mailbox => ({
  mailbox_code: "mbx_01k6zz0000000000000000000c",
  profile_code: PRF,
  provider: "gmail",
  mailbox_email: "x@gmail.test",
  enabled: true,
  sync_state: { gmail_history_id: "500", keep: 1 },
  watch_expires_at: null,
  last_synced_at: null,
});

Deno.test("ingestAttachment: non-PDF content is recorded as ignored, never stored", async () => {
  const db = new FakeDb({ tables: { documents: [], email_events: [] } });
  const outcome = await ingestAttachment(db.asDb(), {
    mailbox: mailbox(),
    route: {
      route_code: "rte_c",
      profile_code: PRF,
      mailbox_code: "mbx",
      bank_code: "FAB",
      sender_allowlist: null,
      subject_keywords: null,
      attachment_filename_regex: null,
      gmail_label_filter: null,
    },
    messageId: "m",
    attachmentKey: "part:1",
    filename: "fake.pdf",
    download: () => Promise.resolve(new TextEncoder().encode("<html>")),
  });
  assertEquals(outcome, "ignored");
  assertEquals(db.tables.email_events[0].detail, "NOT_A_PDF");
  assertEquals(db.tables.documents.length, 0);
});

Deno.test("saveSyncState merges through save_mailbox_sync_state (SRV-15)", async () => {
  const mb = mailbox();
  const db = new FakeDb({
    tables: { email_mailboxes: [{ ...mb, last_synced_at: "2026-10-09T10:00:00Z" }] },
    rpcs: { save_mailbox_sync_state: saveSyncStateRpc },
  });
  // A stale writer (older cursor, older timestamp) can't move either back, and keeps other keys.
  await saveSyncState(db.asDb(), mb, { gmail_history_id: "400", last_error: null }, {
    last_synced_at: "2026-10-09T09:00:00Z",
  });
  const s = db.tables.email_mailboxes[0].sync_state as Record<string, unknown>;
  assertEquals([s.gmail_history_id, s.keep, s.last_error], ["500", 1, null]);
  assertEquals(db.tables.email_mailboxes[0].last_synced_at, "2026-10-09T10:00:00Z");
  assertEquals(mb.sync_state, s, "the in-memory mailbox follows the stored state");

  // A missing cursor is dropped from the patch, so it can never clear the stored one.
  await saveSyncState(db.asDb(), mb, { gmail_history_id: null, provider: "gmail" });
  const patch = db.rpcCalls("save_mailbox_sync_state").at(-1)!.p_patch as Record<string, unknown>;
  assertEquals(patch, { provider: "gmail" });
  assertEquals((db.tables.email_mailboxes[0].sync_state as Record<string, unknown>).gmail_history_id, "500");

  // No fallback: a missing or failing RPC is an error.
  await assertRejects(() => saveSyncState(new FakeDb().asDb(), mailbox(), {}), HttpError);
  const failing = new FakeDb({
    rpcs: { save_mailbox_sync_state: () => ({ data: null, error: { code: "P0002", message: "unknown mailbox" } }) },
  });
  await assertRejects(() => saveSyncState(failing.asDb(), mailbox(), {}), HttpError);
});

Deno.test("worker skips stale messages through begin_document_parse (SRV-20)", async () => {
  const DOC = "doc_01m4dffqf0fz41nq50eaa1sqh2";
  const run = async (data: unknown) => {
    const db = new FakeDb({
      rpcs: {
        begin_document_parse: () => ({ data, error: null }),
        queue_delete: () => ({ data: true, error: null }),
      },
    });
    const r = await processParseMessage(db.asDb(), { msg_id: 3, read_ct: 2, message: { doc_code: DOC } });
    return { r, db };
  };
  const parsed = await run({ skip: "parsed", doc_code: DOC });
  assertEquals(parsed.r, { doc_code: DOC, outcome: "skipped", code: "ALREADY_PARSED" });
  assertEquals(parsed.db.rpcCalls("begin_document_parse"), [{ p_doc_code: DOC, p_attempt: 2 }]);
  assertEquals(parsed.db.rpcCalls("queue_delete"), [{ p_queue: "parse_document", p_msg_id: 3 }]);
  assertEquals(parsed.db.rpcCalls("fail_document").length, 0, "a stale message never touches the document");
  assertEquals((await run({ skip: "failed", doc_code: DOC })).r.code, "ALREADY_FAILED");
  assertEquals((await run(null)).r, { doc_code: DOC, outcome: "skipped" }, "deleted document");
});

Deno.test("worker: a failed status write is not swallowed (SRV-23)", async () => {
  const DOC = "doc_01m4dffqf0fz41nq50eaa1sqh2";
  const db = new FakeDb({
    rpcs: {
      queue_to_dlq: () => ({ data: null, error: null }),
      fail_document: () => ({ data: null, error: { code: "57014", message: "timeout" } }),
    },
  });
  // attempt > MAX_READS: DLQ + fail_document; the failing fail_document must surface.
  await assertRejects(() => processParseMessage(db.asDb(), { msg_id: 1, read_ct: 9, message: { doc_code: DOC } }));
});

Deno.test("pgErrorToHttp hides constraint details but keeps RPC messages (SRV-18)", () => {
  const dup = pgErrorToHttp({ code: "23505", message: 'duplicate key value violates unique constraint "x_key"' });
  assertEquals([dup.status, dup.code, dup.message], [409, "CONFLICT", "this record already exists"]);
  const chk = pgErrorToHttp({ code: "23514", message: 'violates check constraint "statements_check"' });
  assert(!chk.message.includes("statements_check"));
  const rpc = pgErrorToHttp({ code: "22023", message: "cannot demote the last owner of profile prf_x" });
  assertEquals(rpc.message, "cannot demote the last owner of profile prf_x");
});

Deno.test("scrubString and scrubEvent remove free-text email addresses (SRV-18)", () => {
  assertEquals(scrubString("no mailbox for Jane.Doe+x@example.co.uk here"), "no mailbox for [email] here");
  assertEquals(scrubString("sa gmail-push@proj.iam.gserviceaccount.com"), "sa [email]");
  assertEquals(scrubString("version 1.2.3 at 10:00"), "version 1.2.3 at 10:00");
  // deno-lint-ignore no-explicit-any
  const e: any = scrubEvent({
    message: "push for me@gmail.com failed",
    exception: { values: [{ type: "Error", value: "user a@b.io not found" }] },
    extra: { note: "from alerts@bank.ae" },
  });
  const raw = JSON.stringify(e);
  for (const email of ["me@gmail.com", "a@b.io", "alerts@bank.ae"]) assert(!raw.includes(email), email);
});
