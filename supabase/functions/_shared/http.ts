// HTTP helpers: JSON responses, a typed HttpError, and the mapping from Postgres
// SQLSTATEs (raised by our RPCs) to HTTP statuses.

import { corsHeaders } from "./cors.ts";

export class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: unknown,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export function json(body: unknown, status = 200, req?: Request, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...corsHeaders(req), ...extra },
  });
}

/** Postgres SQLSTATE → HTTP status. Our RPCs raise these codes deliberately. */
const SQLSTATE_TO_HTTP: Record<string, [number, string]> = {
  "42501": [403, "FORBIDDEN"], // insufficient_privilege (assert_member / assert_service_role)
  "28000": [401, "UNAUTHORIZED"], // invalid_authorization_specification (service tokens)
  P0002: [404, "NOT_FOUND"], // no_data_found
  "22023": [422, "INVALID_PARAMETER"], // invalid_parameter_value
  "22P02": [422, "INVALID_PARAMETER"], // invalid_text_representation (bad uuid, bad number)
  "22007": [422, "INVALID_PARAMETER"], // invalid_datetime_format
  "22008": [422, "INVALID_PARAMETER"], // datetime_field_overflow
  "23505": [409, "CONFLICT"], // unique_violation
  "23503": [422, "INVALID_REFERENCE"], // foreign_key_violation
  "23514": [422, "INVALID_PARAMETER"], // check_violation
  PGRST301: [401, "UNAUTHORIZED"], // PostgREST: JWT invalid / expired
  PGRST303: [401, "UNAUTHORIZED"], // PostgREST: JWT expired
};

export interface PgLikeError {
  code?: string;
  message?: string;
  details?: string | null;
  hint?: string | null;
}

/**
 * Constraint violations carry schema details (`duplicate key value violates unique
 * constraint "documents_profile_code_sha256_key"`, `Key (x)=(y)`): clients get a fixed
 * message instead (SRV-18). The codes our RPCs raise deliberately (22023, 42501, P0002,
 * 28000) keep their message, which is written for the client.
 */
const FIXED_MESSAGES: Record<string, string> = {
  "23505": "this record already exists",
  "23503": "a referenced record does not exist",
  "23514": "a value is out of the allowed range",
};

/** Map a supabase-js / PostgREST error to an HttpError (500 when unknown). */
export function pgErrorToHttp(err: PgLikeError | null | undefined, fallbackMessage = "database error"): HttpError {
  const code = err?.code ?? "";
  const mapped = SQLSTATE_TO_HTTP[code];
  if (mapped) {
    return new HttpError(mapped[0], mapped[1], FIXED_MESSAGES[code] ?? (err?.message || fallbackMessage));
  }
  return new HttpError(500, "INTERNAL", fallbackMessage, { sqlstate: code || undefined });
}

/** Convert anything thrown by a handler into a JSON error response. */
export function errorResponse(e: unknown, req?: Request): Response {
  if (e instanceof HttpError) {
    return json({ error: { code: e.code, message: e.message } }, e.status, req);
  }
  return json({ error: { code: "INTERNAL", message: "internal error" } }, 500, req);
}

/** True for errors that should not be reported to Sentry (expected client errors). */
export function isExpected(e: unknown): boolean {
  return e instanceof HttpError && e.status < 500;
}

/** Unwrap a supabase-js `{data, error}` result, throwing a mapped HttpError. */
export function unwrap<T>(res: { data: T | null; error: PgLikeError | null }, what = "database error"): T {
  if (res.error) throw pgErrorToHttp(res.error, what);
  return res.data as T;
}

export async function readJson(req: Request, maxBytes = 1_000_000): Promise<unknown> {
  const len = Number(req.headers.get("content-length") ?? "0");
  if (len > maxBytes) throw new HttpError(413, "PAYLOAD_TOO_LARGE", "request body too large");
  const text = await req.text();
  if (text.length > maxBytes) throw new HttpError(413, "PAYLOAD_TOO_LARGE", "request body too large");
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, "INVALID_JSON", "request body is not valid JSON");
  }
}

export function requireMethod(req: Request, method: string): void {
  if (req.method !== method) throw new HttpError(405, "METHOD_NOT_ALLOWED", `use ${method}`);
}
