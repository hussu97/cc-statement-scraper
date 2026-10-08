// CORS for browser callers (apps/web). Server-to-server callers (scraper, pg_cron,
// Pub/Sub) ignore these headers. ALLOWED_ORIGINS is a comma-separated list; when
// unset every origin is allowed (auth is by bearer token, never cookies).

const ALLOWED_HEADERS = [
  "authorization",
  "x-client-info",
  "apikey",
  "content-type",
  "x-profile-key",
  "sentry-trace",
  "baggage",
].join(", ");

export function corsHeaders(req?: Request): Record<string, string> {
  const allowed = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const origin = req?.headers.get("origin") ?? "";
  let allowOrigin = "*";
  if (allowed.length > 0) {
    allowOrigin = allowed.includes(origin) ? origin : allowed[0];
  }
  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Headers": ALLOWED_HEADERS,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

/** Returns a preflight response for OPTIONS, else null. */
export function preflight(req: Request): Response | null {
  if (req.method !== "OPTIONS") return null;
  return new Response(null, { status: 204, headers: corsHeaders(req) });
}
