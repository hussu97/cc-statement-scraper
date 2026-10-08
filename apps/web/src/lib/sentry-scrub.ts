// PII scrubbing for Sentry events and breadcrumbs (CLAUDE.md §6).
// Strips SMS bodies, passwords, tokens, Authorization / X-Profile-Key headers,
// request bodies and email addresses. Only opaque codes survive.

const FILTERED = "[Filtered]";

/** Keys whose values are always removed, wherever they appear. */
const SENSITIVE_KEY = /^(authorization|x-profile-key|apikey|cookie|set-cookie|password|passwd|secret|token|access_token|refresh_token|id_token|body|sms_body|message_body|p_value|p_messages|p_token|p_email|email|token_hash|otp|code_verifier|data|request_body|query)$/i;

const PATTERNS: [RegExp, string][] = [
  [/\bccs_[0-9a-f]{16,}\b/gi, "ccs_[Filtered]"], // service tokens
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, "[jwt]"], // JWTs
  [/\b(Bearer)\s+[A-Za-z0-9._~+/=-]+/gi, "$1 [Filtered]"],
  [/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[email]"],
  [/([?&](?:access_token|refresh_token|token|apikey|code)=)[^&#\s]+/gi, "$1[Filtered]"],
  [/(#access_token=)[^&\s]+/gi, "$1[Filtered]"],
];

export function scrubString(value: string): string {
  let out = value;
  for (const [re, rep] of PATTERNS) out = out.replace(re, rep);
  return out;
}

/** Deep-scrub any JSON-ish value. Depth-limited and cycle-safe. */
export function scrubValue(value: unknown, depth = 0, seen: WeakSet<object> = new WeakSet()): unknown {
  if (typeof value === "string") return scrubString(value);
  if (value === null || typeof value !== "object") return value;
  if (depth > 8) return FILTERED;
  if (seen.has(value)) return "[Circular]";
  seen.add(value);
  if (Array.isArray(value)) return value.map((v) => scrubValue(v, depth + 1, seen));
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    out[k] = SENSITIVE_KEY.test(k) ? FILTERED : scrubValue(v, depth + 1, seen);
  }
  return out;
}

interface ScrubbableEvent {
  request?: { headers?: Record<string, string>; data?: unknown; cookies?: unknown; query_string?: unknown; url?: string };
  user?: Record<string, unknown>;
  breadcrumbs?: ScrubbableBreadcrumb[];
  extra?: Record<string, unknown>;
  contexts?: Record<string, unknown>;
  message?: string;
  exception?: { values?: { value?: string }[] };
  tags?: Record<string, unknown>;
}

interface ScrubbableBreadcrumb {
  message?: string;
  data?: Record<string, unknown>;
  category?: string;
}

export function scrubBreadcrumb<B extends ScrubbableBreadcrumb>(crumb: B): B {
  const out = { ...crumb };
  if (out.message) out.message = scrubString(out.message);
  if (out.data) {
    const data = { ...out.data };
    // supabase-js breadcrumbs carry the request body / filter values.
    delete data.body;
    out.data = scrubValue(data) as Record<string, unknown>;
  }
  return out;
}

/** beforeSend: returns a copy with PII removed. */
export function scrubEvent<E extends ScrubbableEvent>(event: E): E {
  const out: E = { ...event };
  if (out.request) {
    const req = { ...out.request };
    if (req.headers) req.headers = scrubValue(req.headers) as Record<string, string>;
    delete req.data;
    delete req.cookies;
    if (typeof req.query_string === "string") req.query_string = scrubString(req.query_string);
    else delete req.query_string;
    if (req.url) req.url = scrubString(req.url);
    out.request = req;
  }
  if (out.user) {
    // Keep only the opaque id; never email / ip / username.
    out.user = out.user.id ? { id: out.user.id } : {};
  }
  if (out.message) out.message = scrubString(out.message);
  if (out.exception?.values) {
    out.exception = {
      ...out.exception,
      values: out.exception.values.map((v) => ({ ...v, value: v.value ? scrubString(v.value) : v.value })),
    };
  }
  if (out.extra) out.extra = scrubValue(out.extra) as Record<string, unknown>;
  if (out.contexts) out.contexts = scrubValue(out.contexts) as Record<string, unknown>;
  if (out.breadcrumbs) out.breadcrumbs = out.breadcrumbs.map((b) => scrubBreadcrumb(b));
  return out;
}

/** Tags may carry only opaque codes (prf_…, doc_…, txn_…) or short enums. */
export function isSafeTagValue(v: unknown): boolean {
  return typeof v === "string" && /^([a-z]{3}_[0-9a-z]{26}|[A-Za-z0-9_.:-]{1,64})$/.test(v) && !v.includes("@");
}

// ── spans (WEB-03) ──────────────────────────────────────────────────────────
// SDK v11 streams spans (traceLifecycle "stream"), which bypass beforeSend and
// beforeSendTransaction. Router and supabase-js spans carry URLs (with ?q=
// search text), filter values (`db.query`) and request bodies (`db.body`), so
// every span goes through scrubSpan via `beforeSendSpan`.

/** Span attribute keys (or their last dotted segment) whose values are always removed. */
const SENSITIVE_ATTR = /(^|\.)(query|body|request_body|response_body|search|statement|text|cookies?|headers?|authorization|x-profile-key|password|secret|token|email|sms_body|message_body)$/i;

/** Replace every query-string value: "/activity?q=cafe&page=2" → "/activity?q=[Filtered]&page=[Filtered]". */
export function stripQueryValues(value: string): string {
  return value.replace(/([?&][^=&#\s]+=)[^&#\s]*/g, `$1${FILTERED}`);
}

function scrubAttrValue(key: string, value: unknown): unknown {
  if (SENSITIVE_ATTR.test(key) || SENSITIVE_KEY.test(key)) return FILTERED;
  if (typeof value === "string") return stripQueryValues(scrubString(value));
  if (Array.isArray(value)) return value.map((v) => (typeof v === "string" ? stripQueryValues(scrubString(v)) : v));
  if (value && typeof value === "object" && "value" in value) {
    // Typed attribute object { value, type, unit }.
    const obj = value as { value: unknown };
    return { ...obj, value: scrubAttrValue("", obj.value) };
  }
  return value;
}

export function scrubAttributes<A extends Record<string, unknown>>(attrs: A | undefined): A | undefined {
  if (!attrs) return attrs;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(attrs)) out[k] = scrubAttrValue(k, v);
  return out as A;
}

interface ScrubbableSpan {
  name: string;
  attributes?: Record<string, unknown>;
  links?: { attributes?: Record<string, unknown> }[];
}

/** beforeSendSpan: returns a copy with PII removed from the name and attributes. */
export function scrubSpan<S extends ScrubbableSpan>(span: S): S {
  const out: S = { ...span, name: stripQueryValues(scrubString(span.name ?? "")) };
  if (span.attributes) out.attributes = scrubAttributes(span.attributes);
  if (span.links) out.links = span.links.map((l) => ({ ...l, attributes: scrubAttributes(l.attributes) }));
  return out;
}
