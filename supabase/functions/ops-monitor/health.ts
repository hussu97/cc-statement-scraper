// Pure evaluation of public.ops_health() into Sentry issues (one fingerprint per issue type).
//
// Tolerant of the ops_health() version deployed: keys it doesn't return are skipped, and
// the mailbox checks accept either a count or a list of {mailbox_code, ...} rows.

export interface QueueMetrics {
  depth: number;
  oldest_age_s: number | null;
  /** Age of the newest message (pgmq newest_msg_age_sec), when ops_health returns it. */
  newest_age_s?: number | null;
}

/** A mailbox check: a count, or the affected rows (only opaque codes are forwarded). */
export type MailboxCheck = number | { mailbox_code?: string }[] | { count?: number; mailbox_codes?: string[] } | null;

export interface OpsHealth {
  queues?: Record<string, QueueMetrics> | null;
  cron_failures_15m?: { job: string; message: string }[] | null;
  cron_last_success?: Record<string, string | null> | null;
  documents_failed_24h?: number;
  documents_stuck?: number;
  sms_unparsed_24h?: number;
  recon_failed?: number;
  open_reviews?: number;
  /** SRV-10: enabled mailboxes with no successful sync in more than 2 days. */
  mailboxes_stale?: MailboxCheck;
  /** SRV-10: Gmail watches expiring within 24 h (or already expired). */
  gmail_watch_expiring?: MailboxCheck;
  /** SRV-10: enabled mailboxes whose sync_state.last_error is set. */
  mailbox_errors?: MailboxCheck;
}

export interface Thresholds {
  smsUnparsed24h: number;
  openReviews: number;
  /** Oldest parse_document message age (s) before a backlog warning. */
  parseQueueAgeS: number;
  /** ops-monitor's own schedule (s): a DLQ message younger than this is new since the last check. */
  checkIntervalS: number;
}

export const DEFAULT_THRESHOLDS: Thresholds = {
  smsUnparsed24h: 5,
  openReviews: 50,
  parseQueueAgeS: 3 * 3600,
  checkIntervalS: 900,
};

export interface Issue {
  issue: string;
  level: "error" | "warning" | "info";
  message: string;
  extra: Record<string, unknown>;
}

const MAX_CODES = 20;

/** Normalise a mailbox check to a count plus the affected mailbox codes. */
export function mailboxCheck(v: MailboxCheck | undefined): { count: number; codes: string[] } {
  if (v === null || v === undefined) return { count: 0, codes: [] };
  if (typeof v === "number") return { count: Number.isFinite(v) ? v : 0, codes: [] };
  if (Array.isArray(v)) {
    const codes = v.map((r) => r?.mailbox_code).filter((c): c is string => typeof c === "string");
    return { count: v.length, codes: codes.slice(0, MAX_CODES) };
  }
  if (typeof v === "object") {
    const codes = Array.isArray(v.mailbox_codes) ? v.mailbox_codes.filter((c) => typeof c === "string") : [];
    return { count: Number(v.count ?? codes.length) || 0, codes: codes.slice(0, MAX_CODES) };
  }
  return { count: 0, codes: [] };
}

/**
 * SRV-22: a DLQ alerts when messages arrived since the last check (error), then only
 * as a daily reminder while it still holds them (warning), instead of an error every
 * 15 minutes until someone drains it. Without `newest_age_s` (an older ops_health) it
 * falls back to an error on every check.
 */
export function dlqIssue(queue: string, m: QueueMetrics, t: Thresholds): Issue | null {
  const depth = Number(m?.depth ?? 0);
  if (!(depth > 0)) return null;
  const extra = { depth, oldest_age_s: m.oldest_age_s, newest_age_s: m.newest_age_s ?? null };
  const newest = m.newest_age_s;
  if (typeof newest !== "number" || !Number.isFinite(newest)) {
    return { issue: `dlq:${queue}`, level: "error", message: `${queue} holds ${depth} message(s)`, extra };
  }
  // A small margin so cron jitter can't make a fresh message look old.
  if (newest <= t.checkIntervalS + 60) {
    return {
      issue: `dlq:${queue}`,
      level: "error",
      message: `${queue} received new message(s); holds ${depth}`,
      extra,
    };
  }
  // Reminder: the check whose run falls in the first interval of each day of the newest message's age.
  const runsPerDay = Math.max(1, Math.round(86_400 / t.checkIntervalS));
  if (Math.floor(newest / t.checkIntervalS) % runsPerDay === 0) {
    return {
      issue: `dlq:${queue}`,
      level: "warning",
      message: `${queue} still holds ${depth} message(s); drain or requeue them`,
      extra,
    };
  }
  return null;
}

export function evaluateHealth(h: OpsHealth, t: Thresholds = DEFAULT_THRESHOLDS): Issue[] {
  const issues: Issue[] = [];
  const failures = h.cron_failures_15m ?? [];
  if (failures.length > 0) {
    issues.push({
      issue: "cron_failures",
      level: "error",
      message: `pg_cron: ${failures.length} failed run(s) in the last 15 min`,
      // Job names only; return_message can echo SQL arguments.
      extra: { jobs: [...new Set(failures.map((f) => f.job))] },
    });
  }
  for (const [queue, m] of Object.entries(h.queues ?? {})) {
    if (queue.endsWith("_dlq")) {
      const i = dlqIssue(queue, m, t);
      if (i) issues.push(i);
    }
  }
  const parseAge = Number(h.queues?.parse_document?.oldest_age_s ?? 0);
  if (parseAge > t.parseQueueAgeS) {
    issues.push({
      issue: "parse_queue_age",
      level: "warning",
      message: `the oldest parse_document message is ${Math.round(parseAge / 60)} min old`,
      extra: { oldest_age_s: parseAge, depth: h.queues?.parse_document?.depth, threshold_s: t.parseQueueAgeS },
    });
  }
  if (Number(h.documents_stuck ?? 0) > 0) {
    issues.push({
      issue: "documents_stuck",
      level: "error",
      message: `${h.documents_stuck} document(s) stuck for over an hour`,
      extra: { count: h.documents_stuck },
    });
  }
  if (Number(h.documents_failed_24h ?? 0) > 0) {
    issues.push({
      issue: "documents_failed",
      level: "warning",
      message: `${h.documents_failed_24h} document(s) failed to parse in the last 24 h`,
      extra: { count: h.documents_failed_24h },
    });
  }
  if (Number(h.sms_unparsed_24h ?? 0) > t.smsUnparsed24h) {
    issues.push({
      issue: "sms_unparsed",
      level: "warning",
      message: `${h.sms_unparsed_24h} unparsed SMS in the last 24 h (threshold ${t.smsUnparsed24h})`,
      extra: { count: h.sms_unparsed_24h, threshold: t.smsUnparsed24h },
    });
  }
  if (Number(h.recon_failed ?? 0) > 0) {
    issues.push({
      issue: "recon_failed",
      level: "warning",
      message: `${h.recon_failed} statement(s) fail reconciliation`,
      extra: { count: h.recon_failed },
    });
  }
  if (Number(h.open_reviews ?? 0) > t.openReviews) {
    issues.push({
      issue: "review_backlog",
      level: "info",
      message: `${h.open_reviews} open match reviews (threshold ${t.openReviews})`,
      extra: { count: h.open_reviews, threshold: t.openReviews },
    });
  }

  // ── SRV-10: mailbox ingestion health ──
  const errors = mailboxCheck(h.mailbox_errors);
  if (errors.count > 0) {
    issues.push({
      issue: "mailbox_errors",
      level: "error",
      message: `${errors.count} mailbox(es) failing to sync (reconnect or check OAuth)`,
      extra: { count: errors.count, mailbox_codes: errors.codes },
    });
  }
  const stale = mailboxCheck(h.mailboxes_stale);
  if (stale.count > 0) {
    issues.push({
      issue: "mailboxes_stale",
      level: "warning",
      message: `${stale.count} mailbox(es) not synced for over 2 days`,
      extra: { count: stale.count, mailbox_codes: stale.codes },
    });
  }
  const watches = mailboxCheck(h.gmail_watch_expiring);
  if (watches.count > 0) {
    issues.push({
      issue: "gmail_watch_expiring",
      level: "warning",
      message: `${watches.count} Gmail watch(es) expire within 24 h (gmail-watch-renew failing?)`,
      extra: { count: watches.count, mailbox_codes: watches.codes },
    });
  }
  return issues;
}

function envNumber(name: string, fallback: number): number {
  const raw = (Deno.env.get(name) ?? "").trim();
  const v = Number(raw);
  return raw && Number.isFinite(v) && v >= 0 ? v : fallback;
}

export function thresholdsFromEnv(): Thresholds {
  return {
    smsUnparsed24h: envNumber("OPS_SMS_UNPARSED_THRESHOLD", DEFAULT_THRESHOLDS.smsUnparsed24h),
    openReviews: envNumber("OPS_OPEN_REVIEWS_THRESHOLD", DEFAULT_THRESHOLDS.openReviews),
    parseQueueAgeS: envNumber("OPS_PARSE_QUEUE_AGE_S", DEFAULT_THRESHOLDS.parseQueueAgeS),
    checkIntervalS: DEFAULT_THRESHOLDS.checkIntervalS,
  };
}
