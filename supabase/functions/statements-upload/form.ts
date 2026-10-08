// Pure multipart parsing for statements-upload (unit-tested in _tests/upload_test.ts).
//
// Legacy scraper contract (backend jobs.py /api/v1/jobs/upload):
//   files=<pdf> (repeated), bank_code_hint=<BANK> (optional)
// Web / iOS additionally send profile_code and source (upload|ios).

import { HttpError } from "../_shared/http.ts";

export const MAX_FILES = 20;
/**
 * Whole-request cap (SRV-06). One maximum-size PDF (25 MB) plus room for small ones;
 * the body is buffered, then parsed by FormData, so peak memory is ~3x this. The
 * scraper splits uploads into <=20 files and <=32 MB per request to stay under it.
 */
export const MAX_REQUEST_BYTES = 40 * 1024 * 1024;
export const USER_SOURCES = ["upload", "ios"] as const;
export type UserSource = (typeof USER_SOURCES)[number];

export interface UploadForm {
  files: File[];
  bankCodeHint: string | null;
  profileCode: string | null;
  source: UserSource;
}

function field(form: FormData, name: string): string | null {
  const v = form.get(name);
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t || null;
}

export function parseUploadForm(form: FormData): UploadForm {
  const files: File[] = [];
  for (const key of ["files", "file", "files[]"]) {
    for (const v of form.getAll(key)) {
      if (v instanceof File) files.push(v);
    }
  }
  if (files.length === 0) throw new HttpError(400, "NO_FILES", "no files uploaded (use multipart field `files`)");
  if (files.length > MAX_FILES) throw new HttpError(413, "TOO_MANY_FILES", `at most ${MAX_FILES} files per request`);

  const sourceRaw = (field(form, "source") ?? "upload").toLowerCase();
  if (!(USER_SOURCES as readonly string[]).includes(sourceRaw)) {
    throw new HttpError(422, "INVALID_SOURCE", "source must be upload or ios");
  }
  const profileCode = field(form, "profile_code");
  if (profileCode && !/^prf_[0-9a-z]{26}$/.test(profileCode)) {
    throw new HttpError(422, "INVALID_PROFILE", "profile_code is not a profile code");
  }
  return {
    files,
    bankCodeHint: field(form, "bank_code_hint"),
    profileCode,
    source: sourceRaw as UserSource,
  };
}

/**
 * Read the request body, refusing anything over `maxBytes` before buffering it: a
 * declared content-length above the cap is rejected up front, and a chunked body is
 * cut off as soon as it crosses the cap.
 */
export async function readBodyCapped(req: Request, maxBytes: number = MAX_REQUEST_BYTES): Promise<Uint8Array> {
  const tooLarge = () =>
    new HttpError(413, "PAYLOAD_TOO_LARGE", `request exceeds ${Math.floor(maxBytes / 1024 / 1024)} MB; send fewer files`);
  const declared = req.headers.get("content-length");
  if (declared !== null && /^\d+$/.test(declared.trim()) && Number(declared) > maxBytes) throw tooLarge();
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      throw tooLarge();
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

/** Parse a multipart body that has already been read (and size-checked). */
export async function parseMultipart(bytes: Uint8Array, contentType: string): Promise<FormData> {
  try {
    return await new Response(bytes as BlobPart, { headers: { "content-type": contentType } }).formData();
  } catch {
    throw new HttpError(400, "INVALID_MULTIPART", "could not parse multipart body");
  }
}
