// Pure multipart parsing for statements-upload (unit-tested in _tests/upload_test.ts).
//
// Legacy scraper contract (backend jobs.py /api/v1/jobs/upload):
//   files=<pdf> (repeated), bank_code_hint=<BANK> (optional)
// Web / iOS additionally send profile_code and source (upload|ios).

import { HttpError } from "../_shared/http.ts";

export const MAX_FILES = 20;
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
