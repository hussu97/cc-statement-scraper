import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import { isPdf, MAX_PDF_BYTES, sanitizeFilename, sha256Hex, validatePdf } from "../_shared/documents.ts";
import { HttpError } from "../_shared/http.ts";
import { parseUploadForm } from "../statements-upload/form.ts";
import { validateSmsRequest } from "../sms-ingest/validate.ts";

const enc = new TextEncoder();
const PDF = enc.encode("%PDF-1.7\n%âãÏÓ\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n");
const pdfFile = (name: string, bytes: Uint8Array = PDF) => new File([bytes as BlobPart], name, { type: "application/pdf" });
const PRF = "prf_01k6abcdefghjkmnpqrstvwxyz".slice(0, 30);

Deno.test("isPdf checks the %PDF- magic within the first 1024 bytes", () => {
  assert(isPdf(PDF));
  assert(isPdf(new Uint8Array([...enc.encode("junk\r\n"), ...PDF])));
  assert(!isPdf(enc.encode("PK\x03\x04 zip file")));
  assert(!isPdf(enc.encode("%PDF")));
  assert(!isPdf(new Uint8Array([...new Uint8Array(1100), ...PDF])));
});

Deno.test("validatePdf rejects empty, oversized and non-PDF files", () => {
  validatePdf(PDF, "a.pdf");
  assertEquals(assertThrows(() => validatePdf(new Uint8Array(), "a.pdf"), HttpError).code, "EMPTY_FILE");
  assertEquals(assertThrows(() => validatePdf(enc.encode("hello"), "a.pdf"), HttpError).code, "NOT_A_PDF");
  const big = new Uint8Array(MAX_PDF_BYTES + 1);
  big.set(PDF);
  assertEquals(assertThrows(() => validatePdf(big, "a.pdf"), HttpError).status, 413);
});

Deno.test("sha256Hex", async () => {
  assertEquals(await sha256Hex(enc.encode("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

Deno.test("sanitizeFilename keeps the basename only", () => {
  assertEquals(sanitizeFilename("../../etc/x.pdf"), "x.pdf");
  assertEquals(sanitizeFilename("C:\\Users\\me\\FAB Aug.pdf"), "FAB Aug.pdf");
  assertEquals(sanitizeFilename("bad\u0000name\n.pdf"), "badname.pdf");
  assertEquals(sanitizeFilename(""), "statement.pdf");
  assertEquals(sanitizeFilename(null), "statement.pdf");
});

Deno.test("parseUploadForm: legacy scraper contract (repeated files + bank_code_hint)", () => {
  const f = new FormData();
  f.append("files", pdfFile("a.pdf"));
  f.append("files", pdfFile("b.pdf"));
  f.append("bank_code_hint", " fab ");
  const r = parseUploadForm(f);
  assertEquals(r.files.map((x) => x.name), ["a.pdf", "b.pdf"]);
  assertEquals(r.bankCodeHint, "fab");
  assertEquals(r.profileCode, null);
  assertEquals(r.source, "upload");
});

Deno.test("parseUploadForm: web/iOS fields", () => {
  const f = new FormData();
  f.append("file", pdfFile("a.pdf"));
  f.append("profile_code", "prf_01k6zz0000000000000000000a");
  f.append("source", "IOS");
  const r = parseUploadForm(f);
  assertEquals(r.files.length, 1);
  assertEquals(r.profileCode, "prf_01k6zz0000000000000000000a");
  assertEquals(r.source, "ios");
});

Deno.test("parseUploadForm: rejects bad input", () => {
  const empty = new FormData();
  empty.append("bank_code_hint", "FAB");
  assertEquals(assertThrows(() => parseUploadForm(empty), HttpError).code, "NO_FILES");

  const badSource = new FormData();
  badSource.append("files", pdfFile("a.pdf"));
  badSource.append("source", "scraper"); // only token auth may claim scraper
  assertEquals(assertThrows(() => parseUploadForm(badSource), HttpError).code, "INVALID_SOURCE");

  const badProfile = new FormData();
  badProfile.append("files", pdfFile("a.pdf"));
  badProfile.append("profile_code", PRF + "!");
  assertEquals(assertThrows(() => parseUploadForm(badProfile), HttpError).code, "INVALID_PROFILE");

  const many = new FormData();
  for (let i = 0; i < 21; i++) many.append("files", pdfFile(`${i}.pdf`));
  assertEquals(assertThrows(() => parseUploadForm(many), HttpError).status, 413);
});

Deno.test("validateSmsRequest", () => {
  const ok = validateSmsRequest({
    profile_code: "prf_01k6zz0000000000000000000a",
    messages: [{ client_msg_id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", sender: "FAB", body: "x", received_at: "2026-10-08T10:00:00+04:00" }],
  });
  assertEquals(ok.messages[0].client_msg_id, "6f9619ff-8b86-d011-b42d-00c04fc964ff");
  assertEquals(validateSmsRequest({ messages: [{ client_msg_id: "6f9619ff-8b86-d011-b42d-00c04fc964ff", body: "x" }] }).messages[0].sender, "");

  const bad = (b: unknown) => assertThrows(() => validateSmsRequest(b), HttpError);
  bad(null);
  bad({ messages: [] });
  bad({ messages: [{ client_msg_id: "nope", body: "x" }] });
  bad({ messages: [{ client_msg_id: "6f9619ff-8b86-d011-b42d-00c04fc964ff", body: "" }] });
  bad({ messages: [{ client_msg_id: "6f9619ff-8b86-d011-b42d-00c04fc964ff", body: "x", received_at: "yesterday" }] });
  bad({ profile_code: "hussain", messages: [{ client_msg_id: "6f9619ff-8b86-d011-b42d-00c04fc964ff", body: "x" }] });
  const tooMany = Array.from({ length: 201 }, () => ({ client_msg_id: "6f9619ff-8b86-d011-b42d-00c04fc964ff", body: "x" }));
  bad({ messages: tooMany });
  // Errors never echo the SMS body.
  const err = assertThrows(() => validateSmsRequest({ messages: [{ client_msg_id: "x", body: "SECRET BODY" }] }), HttpError);
  assert(!err.message.includes("SECRET"));
});
