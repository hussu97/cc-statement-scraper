// Email route matching, ported from backend/scripts/email_ingestion_common.py
// (route_matches_message and helpers). A route matches a message attachment when
// every configured filter passes; an empty filter always passes.

export interface EmailRoute {
  route_code: string;
  profile_code: string;
  mailbox_code: string;
  bank_code: string;
  enabled?: boolean;
  sender_allowlist: string[] | null;
  subject_keywords: string[] | null;
  attachment_filename_regex: string | null;
  gmail_label_filter: string[] | null;
}

export function normalizeEmail(value: string | null | undefined): string {
  return (value ?? "").trim().toLowerCase();
}

/** Exact (case-insensitive) match against the allowlist. Empty allowlist allows all. */
export function senderAllowed(sender: string, allowlist: string[] | null | undefined): boolean {
  const allowed = (allowlist ?? []).map(normalizeEmail).filter(Boolean);
  if (allowed.length === 0) return true;
  return allowed.includes(normalizeEmail(sender));
}

/** Any keyword is a case-insensitive substring of the subject. Empty list allows all. */
export function subjectAllowed(subject: string, keywords: string[] | null | undefined): boolean {
  const keys = (keywords ?? []).map((k) => String(k).trim().toLowerCase()).filter(Boolean);
  if (keys.length === 0) return true;
  const s = (subject ?? "").trim().toLowerCase();
  return keys.some((k) => s.includes(k));
}

/** Case-insensitive regex search on the filename. An invalid regex never matches. */
export function filenameAllowed(filename: string, regex: string | null | undefined): boolean {
  if (!regex) return true;
  let re: RegExp;
  try {
    re = new RegExp(regex, "i");
  } catch {
    return false;
  }
  return re.test(filename ?? "");
}

/**
 * Gmail label filter (any-of). `labels === null` means the provider has no labels
 * (Outlook), in which case the Gmail-only filter is skipped.
 */
export function labelsAllowed(labels: string[] | null, filter: string[] | null | undefined): boolean {
  const required = (filter ?? []).map((x) => String(x).trim()).filter(Boolean);
  if (required.length === 0 || labels === null) return true;
  const have = new Set(labels.map((x) => String(x).trim()).filter(Boolean));
  return required.some((l) => have.has(l));
}

export interface MessageFacts {
  sender: string;
  subject: string;
  filename: string;
  labels: string[] | null;
}

export function routeMatchesMessage(route: EmailRoute, msg: MessageFacts): boolean {
  if (route.enabled === false) return false;
  return (
    senderAllowed(msg.sender, route.sender_allowlist) &&
    subjectAllowed(msg.subject, route.subject_keywords) &&
    filenameAllowed(msg.filename, route.attachment_filename_regex) &&
    labelsAllowed(msg.labels, route.gmail_label_filter)
  );
}

/** First matching route, in deterministic bank_code order. */
export function pickRoute(routes: EmailRoute[], msg: MessageFacts): EmailRoute | null {
  const sorted = [...routes].sort((a, b) => a.bank_code.localeCompare(b.bank_code));
  return sorted.find((r) => routeMatchesMessage(r, msg)) ?? null;
}

/** `"FAB Alerts" <Alerts@BankFAB.com>` → `alerts@bankfab.com` (port of _sender_from_from_header). */
export function senderFromFromHeader(value: string): string {
  const raw = (value ?? "").trim();
  const left = raw.lastIndexOf("<");
  const right = raw.lastIndexOf(">");
  if (left >= 0 && right > left) return raw.slice(left + 1, right).trim().toLowerCase();
  return raw.toLowerCase();
}

export function isPdfAttachment(filename: string, mimeType: string): boolean {
  return filename.toLowerCase().endsWith(".pdf") || mimeType.toLowerCase() === "application/pdf";
}
