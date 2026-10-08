// statements-upload: accept statement PDFs and queue them for parsing.
//
// Auth (verify_jwt=false; checked here):
//   * Service token (scraper, legacy contract): `Authorization: Bearer ccs_…`,
//     optional `X-Profile-Key`, scope `statements:upload`. The profile is the token's.
//   * User JWT (web / iOS): multipart `profile_code` is required and the caller must
//     be an owner of it. `source` may be `upload` (default) or `ios`.
//
// Response 200: {"uploads": [{"filename", "doc_code", "status": "queued"|"duplicate"}]}

import { withSentry } from "../_shared/sentry.ts";
import { assertOwner, requireUserOrServiceToken } from "../_shared/auth.ts";
import { HttpError, json, requireMethod } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { type DocumentSource, MAX_PDF_BYTES, sanitizeFilename, storeDocument, validateBankHint, validatePdf } from "../_shared/documents.ts";
import { parseMultipart, parseUploadForm, readBodyCapped } from "./form.ts";

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  const caller = await requireUserOrServiceToken(req, "statements:upload");

  const ctype = req.headers.get("content-type") ?? "";
  if (!ctype.toLowerCase().startsWith("multipart/form-data")) {
    throw new HttpError(415, "UNSUPPORTED_MEDIA_TYPE", "send multipart/form-data");
  }
  // Bounded read (SRV-06): never buffer more than MAX_REQUEST_BYTES, with or without content-length.
  const form = parseUploadForm(await parseMultipart(await readBodyCapped(req), ctype));

  let profileCode: string;
  let source: DocumentSource;
  if (caller.kind === "token") {
    profileCode = caller.profileCode;
    if (form.profileCode && form.profileCode !== profileCode) {
      throw new HttpError(403, "FORBIDDEN", "profile_code does not match the service token");
    }
    source = "scraper";
  } else {
    if (!form.profileCode) throw new HttpError(422, "PROFILE_REQUIRED", "profile_code is required");
    await assertOwner(caller, form.profileCode);
    profileCode = form.profileCode;
    source = form.source;
  }

  const svc = serviceClient();
  const bankCode = await validateBankHint(svc, form.bankCodeHint);

  // Read and validate every file before storing any, so a bad file rejects the batch.
  const items: { filename: string; bytes: Uint8Array }[] = [];
  for (const f of form.files) {
    const filename = sanitizeFilename(f.name);
    if (f.size > MAX_PDF_BYTES) {
      throw new HttpError(413, "FILE_TOO_LARGE", `${filename} exceeds the ${MAX_PDF_BYTES / 1024 / 1024} MB limit`);
    }
    const bytes = new Uint8Array(await f.arrayBuffer());
    validatePdf(bytes, filename);
    items.push({ filename, bytes });
  }

  const uploads = [];
  for (const item of items) {
    const r = await storeDocument(svc, {
      profileCode,
      bytes: item.bytes,
      filename: item.filename,
      source,
      bankCodeHint: bankCode,
    });
    uploads.push({ filename: item.filename, doc_code: r.doc_code, status: r.status });
  }
  return json({ uploads }, 200, req);
}

Deno.serve(withSentry("statements-upload", handler));
