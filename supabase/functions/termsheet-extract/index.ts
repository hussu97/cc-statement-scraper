// termsheet-extract: read a structured note's term sheet into the draft terms the user reviews
// before create_structured_note (contract: docs/contracts/termsheet-v1.md).
//
// Auth: user JWT; multipart `profile_code` (the caller must own it) and `file` (one PDF).
// The PDF is kept in the private `term-sheets` bucket at <profile_code>/<sha256>.pdf, then
// sent to Claude as a document (TERMSHEET_LLM_MODEL, default claude-sonnet-5-5) with a JSON
// schema; the answer is normalised and checked (./termsheet.ts).
//
// Response 200: {"draft": {"name", "terms", "termsheet_path", "termsheet_filename",
//                          "extracted_terms"}, "warnings": [...]}
// 422 NOT_A_TERM_SHEET, 422 UNREADABLE (a required field), 503 LLM_NOT_CONFIGURED.
// Nothing from the document is logged or sent to Sentry.

import { withSentry } from "../_shared/sentry.ts";
import { assertOwner, requireUser } from "../_shared/auth.ts";
import { HttpError, json, requireMethod } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { prepareDocument } from "../_shared/documents.ts";
import { encodeBase64 } from "../_shared/deps.ts";
import { llmConfigured, LlmOutputError, structuredCall } from "../_shared/llm.ts";
import { parseMultipart, readBodyCapped } from "../statements-upload/form.ts";
import { normalizeExtraction, NotATermSheet, TERMSHEET_SCHEMA, TERMSHEET_SYSTEM, termsheetModel } from "./termsheet.ts";

const MAX_BYTES = 26 * 1024 * 1024;

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  const caller = await requireUser(req);
  const ctype = req.headers.get("content-type") ?? "";
  if (!ctype.toLowerCase().startsWith("multipart/form-data")) {
    throw new HttpError(415, "UNSUPPORTED_MEDIA_TYPE", "send multipart/form-data");
  }
  const form = await parseMultipart(await readBodyCapped(req, MAX_BYTES), ctype);
  const profileCode = String(form.get("profile_code") ?? "").trim();
  if (!profileCode) throw new HttpError(422, "PROFILE_REQUIRED", "profile_code is required");
  await assertOwner(caller, profileCode);
  const file = form.get("file");
  if (!(file instanceof File)) throw new HttpError(400, "NO_FILE", "send the term sheet as `file`");
  const doc = await prepareDocument(new Uint8Array(await file.arrayBuffer()), file.name || "term-sheet.pdf");
  if (!llmConfigured()) throw new HttpError(503, "LLM_NOT_CONFIGURED", "reading term sheets is not configured");

  const path = `${profileCode}/${doc.sha256}.pdf`;
  const up = await serviceClient().storage.from("term-sheets").upload(path, doc.bytes, {
    contentType: "application/pdf",
    upsert: true,
  });
  if (up.error) throw new HttpError(502, "STORAGE_UPLOAD_FAILED", "could not store the PDF");

  let raw: unknown;
  try {
    raw = await structuredCall({
      model: termsheetModel(),
      effort: "medium",
      maxTokens: 32000,
      timeoutMs: 140_000,
      system: TERMSHEET_SYSTEM,
      schema: TERMSHEET_SCHEMA,
      user: [
        { type: "document", source: { type: "base64", media_type: "application/pdf", data: encodeBase64(doc.bytes) } },
        { type: "text", text: "Transcribe this term sheet's terms." },
      ],
    });
  } catch (e) {
    if (e instanceof LlmOutputError) {
      throw new HttpError(422, "UNREADABLE", `the term sheet could not be read: ${e.message}`);
    }
    throw e;
  }

  try {
    const x = normalizeExtraction(raw);
    return json(
      {
        draft: {
          name: x.name,
          terms: x.terms,
          termsheet_path: path,
          termsheet_filename: doc.filename,
          extracted_terms: raw,
        },
        warnings: x.warnings,
      },
      200,
      req,
    );
  } catch (e) {
    if (e instanceof NotATermSheet) throw new HttpError(422, "NOT_A_TERM_SHEET", e.message);
    throw new HttpError(422, "UNREADABLE", (e as Error).message);
  }
}

Deno.serve(withSentry("termsheet-extract", handler));
