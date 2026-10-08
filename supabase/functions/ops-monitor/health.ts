// Pure evaluation of public.ops_health() into Sentry issues (one fingerprint per issue type).

export interface OpsHealth {
  queues?: Record<string, { depth: number; oldest_age_s: number | null }> | null;
  cron_failures_15m?: { job: string; message: string }[] | null;
  cron_last_success?: Record<string, string | null> | null;
  documents_failed_24h?: number;
  documents_stuck?: number;
  sms_unparsed_24h?: number;
  recon_failed?: number;
  open_reviews?: number;
}

export interface Thresholds {
  smsUnparsed24h: number;
  openReviews: number;
}

export interface Issue {
  issue: string;
  level: "error" | "warning" | "info";
  message: string;
  extra: Record<string, unknown>;
}

export function evaluateHealth(h: OpsHealth, t: Thresholds): Issue[] {
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
    if (queue.endsWith("_dlq") && Number(m?.depth ?? 0) > 0) {
      issues.push({
        issue: `dlq:${queue}`,
        level: "error",
        message: `${queue} holds ${m.depth} message(s)`,
        extra: { depth: m.depth, oldest_age_s: m.oldest_age_s },
      });
    }
  }
  if (Number(h.documents_stuck ?? 0) > 0) {
    issues.push({
      issue: "documents_stuck",
      level: "error",
      message: `${h.documents_stuck} document(s) queued/parsing for over an hour`,
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
  return issues;
}

export function thresholdsFromEnv(): Thresholds {
  return {
    smsUnparsed24h: Number(Deno.env.get("OPS_SMS_UNPARSED_THRESHOLD") ?? "5"),
    openReviews: Number(Deno.env.get("OPS_OPEN_REVIEWS_THRESHOLD") ?? "50"),
  };
}
