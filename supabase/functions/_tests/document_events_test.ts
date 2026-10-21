// Document timeline (public.document_events): the upload-side events storeDocument writes,
// the worker's `parsed` event, and that a failed log never fails an upload.

import { assert, assertEquals } from "jsr:@std/assert@1.0.13";
import { formatBytes, logDocumentEvent, prepareDocument, storeDocument, uploadEvents } from "../_shared/documents.ts";
import { parsedEvent, unrecognisedLines } from "../worker/parse_document.ts";
import { FakeDb, PDF_BYTES, type RpcHandler } from "./fake_db.ts";

Deno.env.delete("SENTRY_DSN");

const PRF = "prf_01k6zz0000000000000000000e";

/** log_document_event as 20261010000400 defines it, recorded in db.tables.document_events. */
const logRpc: RpcHandler = (args, db) => {
  (db.tables.document_events ??= []).push({
    doc_code: args.p_doc_code,
    profile_code: args.p_profile_code,
    stage: args.p_stage,
    level: args.p_level,
    message: args.p_message,
    detail: args.p_detail,
  });
  return { data: "dev_x", error: null };
};

const stages = (db: FakeDb, doc?: string) =>
  (db.tables.document_events ?? []).filter((e) => !doc || e.doc_code === doc).map((e) => e.stage);

Deno.test("formatBytes", () => {
  assertEquals(formatBytes(812), "812 B");
  assertEquals(formatBytes(48 * 1024), "48 KB");
  assertEquals(formatBytes(1.25 * 1024 * 1024), "1.3 MB");
  assertEquals(formatBytes(-1), "0 B");
});

Deno.test("a new upload logs received → stored → queued on its doc_code", async () => {
  const db = new FakeDb({ tables: { documents: [] }, rpcs: { log_document_event: logRpc } });
  const document = await prepareDocument(PDF_BYTES, "FAB Aug.pdf");
  const r = await storeDocument(db.asDb(), { profileCode: PRF, document, source: "upload" });
  assertEquals(stages(db, r.doc_code), ["received", "stored", "queued"]);
  const received = db.tables.document_events[0];
  assertEquals(received.profile_code, PRF);
  assertEquals(received.message, `Received FAB Aug.pdf (${formatBytes(PDF_BYTES.length)}).`);
  assertEquals((received.detail as Record<string, unknown>).source, "upload");
  // The log precedes the row insert only for received/stored; queued follows it.
  const order = db.calls.filter((c) => c.kind === "insert" || c.name === "log_document_event").map((c) =>
    c.kind === "insert" ? "insert" : (c.args as Record<string, unknown>).p_stage
  );
  assertEquals(order, ["received", "stored", "insert", "queued"]);
});

Deno.test("a re-sent file logs received + duplicate on the existing document", async () => {
  const db = new FakeDb({ tables: { documents: [] }, rpcs: { log_document_event: logRpc } });
  const document = await prepareDocument(PDF_BYTES, "a.pdf");
  const first = await storeDocument(db.asDb(), { profileCode: PRF, document, source: "ios" });
  db.tables.document_events = [];
  const dup = await storeDocument(db.asDb(), { profileCode: PRF, document, source: "ios" });
  assertEquals(dup.doc_code, first.doc_code);
  assertEquals(stages(db), ["received", "duplicate"]);
  assert(String(db.tables.document_events[1].message).includes("nothing new to import"));
});

Deno.test("a failing log_document_event never fails the upload", async () => {
  const db = new FakeDb({
    tables: { documents: [] },
    rpcs: { log_document_event: () => ({ data: null, error: { code: "42501", message: "nope" } }) },
  });
  const document = await prepareDocument(PDF_BYTES, "a.pdf");
  const r = await storeDocument(db.asDb(), { profileCode: PRF, document, source: "upload" });
  assertEquals(r.status, "queued");
  // An RPC that throws is swallowed too.
  const throwing = new FakeDb({
    rpcs: {
      log_document_event: () => {
        throw new Error("network");
      },
    },
  });
  await logDocumentEvent(throwing.asDb(), PRF, r.doc_code, uploadEvents.stored());
});

Deno.test("upload event messages never carry more than the file name", () => {
  const e = uploadEvents.duplicate("x.pdf", "failed");
  assertEquals(e.stage, "duplicate");
  assert(e.message.includes("could not be read"));
  assertEquals(uploadEvents.queued().message, "Waiting to be read.");
});

Deno.test("parsedEvent counts statements, lines and warnings, never line text", () => {
  const payload = {
    contract_version: 1,
    parser_version: "2026.10.3",
    bank_code: "SIB",
    document_kind: "history_pdf",
    statements: [
      { lines: [{ description_raw: "SECRET SHOP" }, { description_raw: "X" }], warnings: [] },
      { lines: [{ description_raw: "Y" }], warnings: ["Statement date not found; using max posting month"] },
    ],
  };
  const e = parsedEvent(payload);
  assertEquals(e.stage, "parsed");
  assertEquals(e.level, "warn");
  assertEquals(e.message, "Read the SIB transaction history: 2 statements, 3 lines. 1 warning.");
  assertEquals(e.detail.lines, 3);
  assertEquals(e.detail.statements, 2);
  assert(!JSON.stringify(e).includes("SECRET"));

  const plain = parsedEvent({ bank_code: "fab; drop", document_kind: "statement_pdf", statements: [{ lines: [] }] });
  assertEquals(plain.level, "info");
  assertEquals(plain.message, "Read the statement: 1 statement, 0 lines.");
  assertEquals(plain.detail.bank_code, null);
});

Deno.test("unrecognisedLines passes masked shapes only, never statement text", () => {
  const payload = {
    document_kind: "account_statement_pdf",
    statements: [
      { metadata: { unrecognised_lines: [{ line_no: 3, direction: "debit", shape: "IPP w w w #" }] } },
      {
        metadata: {
          unrecognised_lines: [
            { line_no: 1, direction: "credit", shape: "INWARD REMITTANCE JOHN SMITH" },
            { line_no: 2, direction: "sideways", shape: "w #" },
            { line_no: 4, shape: 42 },
          ],
        },
      },
      { metadata: {} },
      { lines: [] },
    ],
  };
  assertEquals(unrecognisedLines(payload), [
    { shape: "IPP w w w #", direction: "debit" },
    { shape: "?", direction: "credit" },
    { shape: "w #", direction: "?" },
    { shape: "?", direction: "?" },
  ]);
  assertEquals(unrecognisedLines({ statements: "nope" }), []);
});

Deno.test("parsedEvent names a statement of accounts", () => {
  const e = parsedEvent({ bank_code: "ADCB", document_kind: "account_statement_pdf", statements: [{ lines: [] }] });
  assert(e.message.startsWith("Read the ADCB statement of accounts: 1 statement"));
});
