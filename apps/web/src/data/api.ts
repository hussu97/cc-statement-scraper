// Shared helpers for the data layer. Components never import supabase; they
// use the hooks in this folder.
import { FunctionsFetchError, FunctionsHttpError, FunctionsRelayError } from "@supabase/supabase-js";

export class ApiError extends Error {
  code?: string;
  status?: number;
  details?: string;
  constructor(message: string, opts: { code?: string; status?: number; details?: string } = {}) {
    super(message);
    this.name = "ApiError";
    this.code = opts.code;
    this.status = opts.status;
    this.details = opts.details;
  }
}

interface SupabaseLikeError {
  message: string;
  code?: string;
  details?: string | null;
  hint?: string | null;
}

interface SupabaseLikeResponse {
  data: unknown;
  error: SupabaseLikeError | null;
  status?: number;
  count?: number | null;
}

/** The data type of the success branch of a supabase-js response union. */
type DataOf<R> = R extends { error: null; data: infer D } ? D : R extends { data: infer D } ? Exclude<D, null> | null : never;

export function toApiError(error: SupabaseLikeError, status?: number): ApiError {
  return new ApiError(friendlyMessage(error), { code: error.code, status, details: error.details ?? undefined });
}

/** Map well-known SQLSTATEs to sentences people can act on. */
export function friendlyMessage(error: { message: string; code?: string }): string {
  switch (error.code) {
    case "42501":
      return "You don't have permission to do that in this ledger.";
    case "23505":
      return "That already exists.";
    case "PGRST301":
    case "PGRST303":
      return "Your session expired. Sign in again.";
    default:
      return error.message || "Something went wrong.";
  }
}

/** Throw on error, return data (possibly null). */
export function must<R extends SupabaseLikeResponse>(res: R): DataOf<R> {
  if (res.error) throw toApiError(res.error, res.status);
  return res.data as DataOf<R>;
}

/** Throw on error, return the rows (never null). */
export function mustList<R extends SupabaseLikeResponse>(res: R): NonNullable<DataOf<R>> {
  if (res.error) throw toApiError(res.error, res.status);
  return (res.data ?? []) as NonNullable<DataOf<R>>;
}

export function errorMessage(e: unknown): string {
  if (!e) return "";
  if (e instanceof Error) return e.message;
  if (typeof e === "object" && e && "message" in e) return String((e as { message: unknown }).message);
  return String(e);
}

/**
 * An Edge Function error body (`{error: {code, message}}`, see `_shared/http.ts`) as an
 * ApiError carrying the function's own code (`INVITE_COOLDOWN`, `FORBIDDEN`, ...).
 */
export function functionErrorFromBody(body: unknown, status: number | undefined, fallback: string): ApiError {
  const e = body && typeof body === "object" ? (body as { error?: { code?: unknown; message?: unknown } }).error : undefined;
  const code = typeof e?.code === "string" ? e.code : undefined;
  const message = typeof e?.message === "string" && e.message ? e.message : fallback;
  return new ApiError(message, { code, status });
}

export const NETWORK_ERROR_MESSAGE = "Couldn't reach Bank Ledger. Check your connection and try again.";

/** Turn a `supabase.functions.invoke` error into an ApiError (reads the JSON error body). */
export async function functionError(error: unknown): Promise<ApiError> {
  if (error instanceof FunctionsHttpError) {
    const res = error.context as Response | undefined;
    let body: unknown = null;
    try {
      body = await res?.json();
    } catch {
      /* not JSON: keep the generic message */
    }
    return functionErrorFromBody(body, res?.status, error.message);
  }
  if (error instanceof FunctionsFetchError || error instanceof FunctionsRelayError) {
    return new ApiError(NETWORK_ERROR_MESSAGE, { code: "NETWORK" });
  }
  return new ApiError(errorMessage(error) || "Something went wrong.");
}

/** One server-side page of rows plus the exact total for the same filters. */
export interface Page<T> {
  rows: T[];
  total: number;
}

/** PostgREST answers an offset past the last row with 416 / PGRST103. */
export function isRangeNotSatisfiable(error: { code?: string } | null | undefined, status?: number): boolean {
  return error?.code === "PGRST103" || status === 416;
}

/**
 * Fetch one page with `count: 'exact'`. When the page is past the end (a stale
 * URL, or a bulk action that shrank the result set) PostgREST returns 416 with
 * no count, so ask for the count alone and return an empty page: the screen
 * then clamps to the last page instead of showing a raw error (WEB-01).
 */
export async function fetchPage<T>(
  run: () => PromiseLike<SupabaseLikeResponse>,
  countOnly: () => PromiseLike<SupabaseLikeResponse>,
): Promise<Page<T>> {
  const res = await run();
  if (res.error && isRangeNotSatisfiable(res.error, res.status)) {
    const head = await countOnly();
    if (head.error) throw toApiError(head.error, head.status);
    return { rows: [], total: head.count ?? 0 };
  }
  if (res.error) throw toApiError(res.error, res.status);
  return { rows: (res.data ?? []) as T[], total: res.count ?? 0 };
}
