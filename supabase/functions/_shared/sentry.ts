// Sentry for Edge Functions (CLAUDE.md §3.1, §6). Every function's index.ts does:
//
//   Deno.serve(withSentry("name", handler));
//
// Sentry is initialised once per isolate when SENTRY_DSN is set and SENTRY_ENVIRONMENT
// is not local ('', local, development, test — unset means local).
//
// Request isolation (SRV-18, verified by _tests/sentry_scope_test.ts): the Deno SDK has
// no async context strategy, so a scope tag set during one request leaks into events of
// another request interleaved in the same isolate. Per-request tags therefore live in an
// AsyncLocalStorage (`function`, `execution_id`, and anything set with setRequestTag)
// and are applied by an event processor; nothing request-specific is written to Sentry's
// shared scopes. Use setRequestTag, never Sentry.getCurrentScope().setTag, in handlers.
//
// Events go through scrubEvent(), which removes request bodies, auth headers, query
// strings, email addresses and any body/sms/password/token-like fields before they
// leave the isolate.

import { AsyncLocalStorage } from "node:async_hooks";
import { Sentry } from "./deps.ts";
import { errorResponse, HttpError, isExpected } from "./http.ts";
import { preflight } from "./cors.ts";

// deno-lint-ignore no-explicit-any
type AnyEvent = Record<string, any>;

const SENSITIVE_HEADERS = new Set([
  "authorization",
  "proxy-authorization",
  "x-profile-key",
  "x-cron-secret",
  "x-parser-secret",
  "apikey",
  "cookie",
  "set-cookie",
]);

// Field names whose values are never sent: SMS text, passwords, tokens, signed URLs, emails.
const SENSITIVE_KEY_EXACT =
  /^(body|raw_body|sms|sms_body|message_body|messages|text|password|passwords|password_candidates|token|access_token|refresh_token|id_token|service_token|secret|client_secret|authorization|apikey|api_key|settings|document_url|signed_url|signedurl|email|mailbox_email|sender|subject|merchant|merchant_raw|description|description_raw|data)$/i;
const SENSITIVE_KEY_SUBSTR = /(password|secret|token|authorization|api[_-]?key|cookie)/i;

const FILTERED = "[Filtered]";

export function isSensitiveKey(key: string): boolean {
  return SENSITIVE_KEY_EXACT.test(key) || SENSITIVE_KEY_SUBSTR.test(key);
}

// Email addresses in free text (SRV-18): local part, @, a dotted domain. Service-account
// style addresses are emails too and are filtered the same way.
const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g;

/** Remove bearer tokens, service tokens, JWTs, email addresses and URL query strings from free text. */
export function scrubString(s: string): string {
  return s
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, `Bearer ${FILTERED}`)
    .replace(/ccs_[0-9a-f]{16,}/gi, FILTERED)
    .replace(/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/g, FILTERED)
    .replace(/(https?:\/\/[^\s?#"']+)\?[^\s#"']*/gi, `$1?${FILTERED}`)
    .replace(EMAIL_RE, "[email]");
}

function scrubValue(v: unknown, depth: number): unknown {
  if (depth > 8) return FILTERED;
  if (typeof v === "string") return scrubString(v);
  if (Array.isArray(v)) return v.map((x) => scrubValue(x, depth + 1));
  if (v && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      out[k] = isSensitiveKey(k) ? FILTERED : scrubValue(val, depth + 1);
    }
    return out;
  }
  return v;
}

function scrubHeaders(h: unknown): Record<string, string> | undefined {
  if (!h || typeof h !== "object") return undefined;
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(h as Record<string, unknown>)) {
    out[k] = SENSITIVE_HEADERS.has(k.toLowerCase()) ? FILTERED : scrubString(String(v));
  }
  return out;
}

function stripQuery(url: unknown): unknown {
  if (typeof url !== "string") return url;
  const i = url.search(/[?#]/);
  return i >= 0 ? url.slice(0, i) : url;
}

/**
 * Pure scrubber used as beforeSend / beforeSendTransaction. Returns a scrubbed copy;
 * never throws (an unscrubbable event is dropped by returning null).
 */
export function scrubEvent<T extends AnyEvent | null>(event: T): T {
  if (!event) return event;
  let e: AnyEvent;
  try {
    e = structuredClone(event) as AnyEvent;
  } catch {
    return null as T;
  }
  if (e.request) {
    delete e.request.data;
    delete e.request.cookies;
    delete e.request.query_string;
    delete e.request.env;
    e.request.url = stripQuery(e.request.url);
    if (e.request.headers) e.request.headers = scrubHeaders(e.request.headers);
  }
  if (e.user) {
    e.user = e.user.id ? { id: String(e.user.id) } : undefined;
  }
  if (typeof e.message === "string") e.message = scrubString(e.message);
  if (e.logentry?.message) e.logentry.message = scrubString(String(e.logentry.message));
  if (e.logentry?.params) e.logentry.params = FILTERED;
  for (const ex of e.exception?.values ?? []) {
    if (typeof ex.value === "string") ex.value = scrubString(ex.value);
    for (const fr of ex.stacktrace?.frames ?? []) delete fr.vars;
  }
  if (e.extra) e.extra = scrubValue(e.extra, 0);
  if (e.contexts) e.contexts = scrubValue(e.contexts, 0);
  if (e.tags) e.tags = scrubValue(e.tags, 0);
  if (Array.isArray(e.breadcrumbs)) e.breadcrumbs = e.breadcrumbs.map(scrubBreadcrumb);
  else if (e.breadcrumbs?.values) e.breadcrumbs.values = e.breadcrumbs.values.map(scrubBreadcrumb);
  for (const span of e.spans ?? []) {
    if (span.data) span.data = scrubValue(span.data, 0);
    if (typeof span.description === "string") span.description = scrubString(span.description);
  }
  return e as T;
}

export function scrubBreadcrumb<T extends AnyEvent | null>(b: T): T {
  if (!b) return b;
  const out: AnyEvent = { ...b };
  if (typeof out.message === "string") out.message = scrubString(out.message);
  if (out.data) {
    const d = scrubValue(out.data, 0) as AnyEvent;
    if (typeof b.data?.url === "string") d.url = stripQuery(b.data.url);
    out.data = d;
  }
  return out as T;
}

// ── runtime ─────────────────────────────────────────────────────────────────

let initialised = false;
let enabled = false;

/** Environments that never report, even with a DSN set (local replays, tests). Unset = "local". */
export const LOCAL_ENVIRONMENTS: ReadonlySet<string> = new Set(["", "local", "development", "test"]);

export function sentryEnvironment(): string {
  return (Deno.env.get("SENTRY_ENVIRONMENT") ?? "").trim() || "local";
}

/** True when events should be sent: a DSN is set and the environment isn't local. */
export function sentryActive(environment: string | undefined, dsn: string | undefined): boolean {
  return Boolean((dsn ?? "").trim()) && !LOCAL_ENVIRONMENTS.has((environment ?? "").trim().toLowerCase());
}

/**
 * Gmail ingestion isn't configured yet, so its errors are muted: nothing from a
 * `gmail-*` function, or tagged/labelled as Gmail, reaches Sentry until
 * GMAIL_SENTRY_ALERTS=on is set (PRODUCTION §2.5). Pure, so it is unit-tested.
 */
export function gmailAlertsEnabled(value = Deno.env.get("GMAIL_SENTRY_ALERTS")): boolean {
  return /^(on|true|1|yes)$/i.test((value ?? "").trim());
}

// deno-lint-ignore no-explicit-any
export function isGmailEvent(event: any): boolean {
  const tags = event?.tags ?? {};
  if (String(tags.function ?? "").startsWith("gmail-") || String(tags.provider ?? "") === "gmail") return true;
  const text = String(event?.message ?? event?.logentry?.message ?? "");
  return /^gmail[\s-]/i.test(text);
}

function ensureInit(): boolean {
  if (initialised) return enabled;
  initialised = true;
  const dsn = Deno.env.get("SENTRY_DSN");
  if (!sentryActive(sentryEnvironment(), dsn)) return false;
  Sentry.init({
    dsn,
    environment: sentryEnvironment(),
    release: Deno.env.get("SENTRY_RELEASE") || undefined,
    sendDefaultPii: false,
    // The Deno default integrations hook process-level APIs the edge runtime
    // doesn't expose; requests are wrapped explicitly below instead.
    defaultIntegrations: false,
    integrations: [Sentry.dedupeIntegration()],
    tracesSampleRate: Number(Deno.env.get("SENTRY_TRACES_SAMPLE_RATE") ?? "0.1"),
    // deno-lint-ignore no-explicit-any
    beforeSend: (event: any) => (!gmailAlertsEnabled() && isGmailEvent(event) ? null : scrubEvent(event)),
    // deno-lint-ignore no-explicit-any
    beforeSendTransaction: (event: any) => scrubEvent(event),
    // deno-lint-ignore no-explicit-any
    beforeBreadcrumb: (b: any) => scrubBreadcrumb(b),
  });
  // ledger-backend is shared with the parser (service=parser); `function` is set per request.
  Sentry.setTag("service", "edge");
  const region = Deno.env.get("SB_REGION");
  if (region) Sentry.setTag("region", region);
  // Per-request tags from the AsyncLocalStorage; tags set explicitly on the event win.
  // deno-lint-ignore no-explicit-any
  Sentry.addEventProcessor((event: any) => {
    const tags = requestContext.getStore()?.tags;
    if (tags) event.tags = { ...tags, ...(event.tags ?? {}) };
    return event;
  });
  enabled = true;
  return true;
}

interface RequestContext {
  tags: Record<string, string>;
}

const requestContext = new AsyncLocalStorage<RequestContext>();

/** Tag every event of the current request (opaque codes only). No-op outside withSentry. */
export function setRequestTag(key: string, value: string | number): void {
  const store = requestContext.getStore();
  if (store) store.tags[key] = String(value);
}

export function sentryEnabled(): boolean {
  return ensureInit();
}

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

/** Keep the isolate alive for `p` after the response is sent (no-op outside the edge runtime). */
export function waitUntil(p: Promise<unknown>): boolean {
  if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) {
    EdgeRuntime.waitUntil(p);
    return true;
  }
  return false;
}

function flushLater(): void {
  if (!enabled) return;
  const p = Sentry.flush(2000).catch(() => false);
  if (!waitUntil(p)) void p;
}

export interface CaptureOptions {
  level?: "fatal" | "error" | "warning" | "info" | "debug";
  tags?: Record<string, string | number | undefined>;
  extra?: Record<string, unknown>;
  fingerprint?: string[];
}

function cleanTags(tags?: Record<string, string | number | undefined>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(tags ?? {})) if (v !== undefined && v !== null) out[k] = String(v);
  return out;
}

/** captureMessage that no-ops without a DSN. Tags must be opaque codes only. */
export function captureMessage(message: string, opts: CaptureOptions = {}): void {
  if (!ensureInit()) return;
  Sentry.withScope((scope) => {
    scope.setLevel(opts.level ?? "info");
    scope.setTags(cleanTags(opts.tags));
    if (opts.extra) scope.setExtras(opts.extra);
    if (opts.fingerprint) scope.setFingerprint(opts.fingerprint);
    Sentry.captureMessage(message);
  });
  flushLater();
}

export function captureException(err: unknown, opts: CaptureOptions = {}): void {
  if (!ensureInit()) return;
  Sentry.withScope((scope) => {
    scope.setLevel(opts.level ?? "error");
    scope.setTags(cleanTags(opts.tags));
    if (opts.extra) scope.setExtras(opts.extra);
    if (opts.fingerprint) scope.setFingerprint(opts.fingerprint);
    Sentry.captureException(err);
  });
  flushLater();
}

/** Headers to forward to downstream services (parser) to continue the trace. */
export function traceHeaders(): Record<string, string> {
  if (!ensureInit()) return {};
  const data = Sentry.getTraceData() as Record<string, string | undefined>;
  const out: Record<string, string> = {};
  if (data["sentry-trace"]) out["sentry-trace"] = data["sentry-trace"];
  if (data.baggage) out.baggage = data.baggage;
  return out;
}

export { Sentry };

export type Handler = (req: Request) => Promise<Response> | Response;

/** Wrap a function handler: CORS preflight, Sentry scope + trace, error mapping, flush. */
export function withSentry(name: string, handler: Handler): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    const pre = preflight(req);
    if (pre) return pre;

    const run = async (): Promise<Response> => {
      try {
        const url = new URL(req.url);
        if (url.searchParams.get("debug_sentry") === "1" && sentryEnvironment() !== "production") {
          throw new Error(`Sentry debug trigger (${name})`);
        }
        return await handler(req);
      } catch (e) {
        if (!isExpected(e)) {
          if (!(e instanceof HttpError)) console.error(`${name}: unhandled error`, scrubString(String(e)));
          captureException(e, { tags: { function: name } });
        }
        return errorResponse(e, req);
      }
    };

    if (!ensureInit()) return await run();

    const tags: Record<string, string> = { function: name };
    const execId = Deno.env.get("SB_EXECUTION_ID");
    if (execId) tags.execution_id = execId;
    return await requestContext.run({ tags }, () =>
      Sentry.withScope(async () => {
        try {
          return await Sentry.continueTrace(
            {
              sentryTrace: req.headers.get("sentry-trace") ?? undefined,
              baggage: req.headers.get("baggage") ?? undefined,
            },
            () =>
              Sentry.startSpan(
                { name: `${req.method} /${name}`, op: "http.server", forceTransaction: true },
                async (span) => {
                  const res = await run();
                  span.setAttribute("http.response.status_code", res.status);
                  return res;
                },
              ),
          );
        } finally {
          flushLater();
        }
      }));
  };
}
