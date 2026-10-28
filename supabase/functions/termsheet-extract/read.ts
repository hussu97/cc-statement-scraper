// Reading one term-sheet PDF into the draft create_structured_note takes: store it in the private
// `term-sheets` bucket at <profile_code>/<sha256>.pdf, send it to Claude with the JSON schema,
// normalise and check the answer. Shared by termsheet-extract (a user's upload) and
// swissquote-sync (the term sheet attached to a trade ticket). Nothing from the document is logged.

import { HttpError } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { prepareDocument } from "../_shared/documents.ts";
import { encodeBase64 } from "../_shared/base64.ts";
import { LlmOutputError, structuredCall } from "../_shared/llm.ts";
import { normalizeExtraction, NotATermSheet, TERMSHEET_SCHEMA, TERMSHEET_SYSTEM, termsheetModel } from "./termsheet.ts";

export interface TermSheetDraft {
  name: string;
  terms: unknown;
  termsheet_path: string;
  termsheet_filename: string;
  extracted_terms: unknown;
}

/** Throws HttpError 422 NOT_A_TERM_SHEET / UNREADABLE, 502 STORAGE_UPLOAD_FAILED. */
export async function readTermSheet(
  profileCode: string,
  bytes: Uint8Array,
  filename: string,
): Promise<{ draft: TermSheetDraft; warnings: string[] }> {
  const doc = await prepareDocument(bytes, filename || "term-sheet.pdf");
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
    return {
      draft: {
        name: x.name,
        terms: x.terms,
        termsheet_path: path,
        termsheet_filename: doc.filename,
        extracted_terms: raw,
      },
      warnings: x.warnings,
    };
  } catch (e) {
    if (e instanceof NotATermSheet) throw new HttpError(422, "NOT_A_TERM_SHEET", e.message);
    throw new HttpError(422, "UNREADABLE", (e as Error).message);
  }
}
