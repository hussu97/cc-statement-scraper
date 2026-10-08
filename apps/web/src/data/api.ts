// Shared helpers for the data layer. Components never import supabase; they
// use the hooks in this folder.
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
