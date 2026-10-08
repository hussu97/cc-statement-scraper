// Pure evaluation of public.ops_health() (migration 20261009000400) into Sentry issues,
// one fingerprint per issue type.

export interface QueueMetrics {
  depth: number;
  oldest_age_s: number | null;
  /** Age of the newest message (pgmq newest_msg_age_sec); null when the queue is empty. */
  newest_age_s: number | null;
  /** Messages ever sent to the queue. */
  total: number;
}

/** One mailbox in mailboxes_stale / gmail_watch_expiring / mailbox_errors (opaque codes only). */
export interface MailboxRow {
  mailbox_code: string;
  provider?: string;
  last_synced_at?: string | null;
  watch_expires_at?: string | null;
  /** mailbox_errors: sync_state.last_error.code (e.g. TOKEN_REFRESH_FAILED:invalid_grant). */
  code?: string | null;
  at?: string | null;
}

export interface OpsHealth {
  queues?: Record<string, QueueMetrics> | null;
  cron_failures_15m?: { job: string; message: string }[] | null;
  cron_last_success?: Record<string, string | null> | null;
  documents_failed_24h?: number;
  /** Documents in `parsing` for over an hour. */
  documents_stuck?: number;
  /** Age (s) of the oldest `queued` document; null when none is queued. */
  documents_queued_oldest_age_s?: number | null;
  sms_unparsed_24h?: number;
  /** Statements failing reconciliation, last 7 days. */
  recon_failed?: number;
  /** Open match reviews created in the last 7 days. */
  open_reviews?: number;
  open_reviews_total?: number;
  /** Rows in private.job_errors (per-profile cron failures), last 24 h. */
  job_errors_24h?: number;
  mailboxes_stale?: MailboxRow[] | null;
  gmail_watch_expiring?: MailboxRow[] | null;
  mailbox_errors?: MailboxRow[] | null;
}

export interface Thresholds {
  smsUnparsed24h: number;
  openReviews: number;
  /** Oldest queued document age (s) before a backlog warning. */
  queuedDocumentAgeS: number;
  /** ops-monitor's own schedule (s): a DLQ message younger than this arrived since the last check. */
  checkIntervalS: number;
}

export const DEFAULT_THRESHOLDS: Thresholds = {
  smsUnparsed24h: 5,
  openReviews: 50,
  queuedDocumentAgeS: 3 * 3600,
  checkIntervalS: 900,
};

export interface Issue {
  issue: string;
  level: "error" | "warning" | "info";
  message: string;
  extra: Record<string, unknown>;
}

const MAX_CODES = 20;

function rows(v: MailboxRow[] | null | undefined): MailboxRow[] {
  return Array.isArray(v) ? v.filter((r) => r && typeof r.mailbox_code === "string") : [];
}

/**
 * SRV-22: a DLQ is an error when it grew since the last check (its newest message is
 * younger than the check interval), then a daily warning while it still holds messages,
 * instead of an error every 15 minutes until someone runs drain_dlq / requeue_dlq.
 */
export function dlqIssue(queue: string, m: QueueMetrics, t: Thresholds): Issue | null {
  const depth = Number(m?.depth ?? 0);
  if (!(depth > 0)) return null;
  const newest = Number(m.newest_age_s);
  const extra = { depth, oldest_age_s: m.oldest_age_s, newest_age_s: m.newest_age_s, total: m.total };
  if (!Number.isFinite(newest) || newest < t.checkIntervalS) {
    return {
      issue: `dlq:${queue}`,
      level: "error",
      message: `${queue} received new message(s); holds ${depth}`,
      extra,
    };
  }
  // Reminder: the one check per day whose run falls in the first interval of a day of age.
  const runsPerDay = Math.max(1, Math.round(86_400 / t.checkIntervalS));
  if (Math.floor(newest / t.checkIntervalS) % runsPerDay === 0) {
    return {
      issue: `dlq:${queue}`,
      level: "warning",
      message: `${queue} still holds ${depth} message(s); drain_dlq or requeue_dlq`,
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
  if (Number(h.job_errors_24h ?? 0) > 0) {
    issues.push({
      issue: "job_errors",
      level: "error",
      message: `${h.job_errors_24h} per-profile cron job error(s) in the last 24 h (private.job_errors)`,
      extra: { count: h.job_errors_24h },
    });
  }
  for (const [queue, m] of Object.entries(h.queues ?? {})) {
    if (queue.endsWith("_dlq")) {
      const i = dlqIssue(queue, m, t);
      if (i) issues.push(i);
    }
  }
  const queuedAge = Number(h.documents_queued_oldest_age_s ?? 0);
  if (queuedAge > t.queuedDocumentAgeS) {
    issues.push({
      issue: "documents_queued_age",
      level: "warning",
      message: `the oldest queued document has waited ${Math.round(queuedAge / 60)} min`,
      extra: {
        oldest_age_s: queuedAge,
        parse_queue_depth: h.queues?.parse_document?.depth,
        threshold_s: t.queuedDocumentAgeS,
      },
    });
  }
  if (Number(h.documents_stuck ?? 0) > 0) {
    issues.push({
      issue: "documents_stuck",
      level: "error",
      message: `${h.documents_stuck} document(s) parsing for over an hour`,
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
      message: `${h.recon_failed} statement(s) failed reconciliation in the last 7 days`,
      extra: { count: h.recon_failed },
    });
  }
  if (Number(h.open_reviews ?? 0) > t.openReviews) {
    issues.push({
      issue: "review_backlog",
      level: "info",
      message: `${h.open_reviews} match reviews opened in the last 7 days are still open (threshold ${t.openReviews})`,
      extra: { count: h.open_reviews, total_open: h.open_reviews_total, threshold: t.openReviews },
    });
  }

  // ── SRV-10: mailbox ingestion health ──
  const errors = rows(h.mailbox_errors);
  if (errors.length > 0) {
    issues.push({
      issue: "mailbox_errors",
      level: "error",
      message: `${errors.length} mailbox(es) failing to sync (reconnect or check OAuth)`,
      extra: {
        count: errors.length,
        mailboxes: errors.slice(0, MAX_CODES).map((r) => ({
          mailbox_code: r.mailbox_code,
          provider: r.provider,
          code: r.code,
        })),
      },
    });
  }
  const stale = rows(h.mailboxes_stale);
  if (stale.length > 0) {
    issues.push({
      issue: "mailboxes_stale",
      level: "warning",
      message: `${stale.length} mailbox(es) not synced for over 2 days`,
      extra: { count: stale.length, mailbox_codes: stale.slice(0, MAX_CODES).map((r) => r.mailbox_code) },
    });
  }
  const watches = rows(h.gmail_watch_expiring);
  if (watches.length > 0) {
    issues.push({
      issue: "gmail_watch_expiring",
      level: "warning",
      message: `${watches.length} Gmail watch(es) missing or expiring within 24 h (gmail-watch-renew failing?)`,
      extra: { count: watches.length, mailbox_codes: watches.slice(0, MAX_CODES).map((r) => r.mailbox_code) },
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
    queuedDocumentAgeS: envNumber("OPS_QUEUED_DOCUMENT_AGE_S", DEFAULT_THRESHOLDS.queuedDocumentAgeS),
    checkIntervalS: DEFAULT_THRESHOLDS.checkIntervalS,
  };
}
