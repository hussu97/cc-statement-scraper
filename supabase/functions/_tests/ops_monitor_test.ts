// ops-monitor evaluateHealth against the exact ops_health() shapes of migration
// 20261009000400 (SRV-10, SRV-22, DB-25, DB-38).

import { assertEquals } from "jsr:@std/assert@1.0.13";
import {
  DEFAULT_THRESHOLDS,
  dlqIssue,
  evaluateHealth,
  mailboxErrorSummary,
  type MailboxRow,
  type OpsHealth,
} from "../ops-monitor/health.ts";

const q = (depth: number, newest: number | null, total = depth) => ({
  depth,
  oldest_age_s: newest,
  newest_age_s: newest,
  total,
});

/** A healthy ops_health() payload, as the RPC returns it. */
function healthy(): OpsHealth {
  return {
    queues: {
      parse_document: q(3, 10, 40),
      parse_document_dlq: q(0, null, 2),
      llm_categorize: q(0, null),
      llm_categorize_dlq: q(0, null),
      sms_fallback: q(0, null),
      sms_fallback_dlq: q(0, null),
      storage_cleanup: q(0, null),
    },
    cron_failures_15m: [],
    cron_last_success: { "ledger-worker-kick": "2026-10-09T10:00:00Z" },
    documents_failed_24h: 0,
    documents_stuck: 0,
    documents_queued_oldest_age_s: null,
    sms_unparsed_24h: 5,
    recon_failed: 0,
    open_reviews: 3,
    open_reviews_total: 120,
    job_errors_24h: 0,
    mailboxes_stale: [],
    gmail_watch_expiring: [],
    mailbox_errors: [],
  };
}

Deno.test("evaluateHealth: a healthy payload raises nothing", () => {
  assertEquals(evaluateHealth(healthy()), []);
});

Deno.test("evaluateHealth raises one issue per problem type", () => {
  const issues = evaluateHealth({
    ...healthy(),
    queues: { sms_fallback_dlq: q(2, 60), parse_document_dlq: q(1, 5) },
    cron_failures_15m: [{ job: "ledger-worker-kick", message: "boom" }, { job: "ledger-worker-kick", message: "boom" }],
    documents_failed_24h: 1,
    documents_stuck: 2,
    documents_queued_oldest_age_s: 4 * 3600,
    sms_unparsed_24h: 6,
    recon_failed: 1,
    open_reviews: 51,
    job_errors_24h: 3,
    mailbox_errors: [{
      mailbox_code: "mbx_err",
      provider: "gmail",
      code: "TOKEN_REFRESH_FAILED:invalid_grant",
      at: "t",
    }],
    mailboxes_stale: [{ mailbox_code: "mbx_old", provider: "outlook", last_synced_at: "2026-10-01T00:00:00Z" }],
    gmail_watch_expiring: [{ mailbox_code: "mbx_w", watch_expires_at: null }],
  });
  const by = Object.fromEntries(issues.map((i) => [i.issue, i]));
  assertEquals(Object.keys(by).sort(), [
    "cron_failures",
    "dlq:parse_document_dlq",
    "dlq:sms_fallback_dlq",
    "documents_failed",
    "documents_queued_age",
    "documents_stuck",
    "gmail_watch_expiring",
    "job_errors",
    "mailbox_errors",
    "mailboxes_stale",
    "recon_failed",
    "review_backlog",
    "sms_unparsed",
  ]);
  assertEquals(by.cron_failures.extra, { jobs: ["ledger-worker-kick"] }); // no return_message
  assertEquals([by.job_errors.level, by.job_errors.extra.count], ["error", 3]);
  assertEquals(by.mailbox_errors.level, "error");
  assertEquals(by.mailbox_errors.extra.mailboxes, [
    { mailbox_code: "mbx_err", provider: "gmail", code: "TOKEN_REFRESH_FAILED:invalid_grant" },
  ]);
  assertEquals(by.mailboxes_stale.extra.mailbox_codes, ["mbx_old"]);
  assertEquals(by.gmail_watch_expiring.extra.mailbox_codes, ["mbx_w"]);
  assertEquals(by.review_backlog.extra.total_open, 120);
  assertEquals(by.documents_queued_age.level, "warning");
});

Deno.test("evaluateHealth: a queued backlog under the threshold is not an issue", () => {
  assertEquals(evaluateHealth({ ...healthy(), documents_queued_oldest_age_s: 3600 }), []);
});

Deno.test("dlqIssue alerts when the DLQ grew, then once a day (SRV-22)", () => {
  const t = DEFAULT_THRESHOLDS;
  assertEquals(dlqIssue("parse_document_dlq", q(0, null), t), null);
  // A message arrived since the last check (newest_age_s < 900).
  assertEquals(dlqIssue("parse_document_dlq", q(3, 120), t)?.level, "error");
  assertEquals(dlqIssue("parse_document_dlq", q(3, 899), t)?.level, "error");
  // Nothing new: silent, except one reminder per day of age.
  const fired = [];
  for (let age = t.checkIntervalS; age < 2 * 86_400; age += t.checkIntervalS) {
    const i = dlqIssue("parse_document_dlq", q(3, age + 7), t);
    if (i) fired.push([age, i.level]);
  }
  assertEquals(fired, [[86_400, "warning"]]);
});

Deno.test("mailbox_errors names the codes and the fix: a refused client is the secret, not the mailbox", () => {
  const title = (mailbox_errors: MailboxRow[]) =>
    evaluateHealth({ ...healthy(), mailbox_errors }).find((i) => i.issue === "mailbox_errors")?.message;
  // 2026-10-21: a glued line in the pushed env file broke GMAIL_OAUTH_CLIENT_SECRET.
  assertEquals(
    title([{ mailbox_code: "mbx_g", provider: "gmail", code: "TOKEN_REFRESH_FAILED:invalid_client" }]),
    "1 mailbox(es) failing to sync: gmail TOKEN_REFRESH_FAILED:invalid_client " +
      "(check the OAuth client secret (reconnecting won't help))",
  );
  assertEquals(
    title([{ mailbox_code: "mbx_g", provider: "gmail", code: "TOKEN_REFRESH_FAILED:invalid_grant" }]),
    "1 mailbox(es) failing to sync: gmail TOKEN_REFRESH_FAILED:invalid_grant (reconnect the mailbox)",
  );
  assertEquals(
    title([
      { mailbox_code: "mbx_o", provider: "outlook", code: "HTTP_401" },
      { mailbox_code: "mbx_x", code: null },
    ]),
    "2 mailbox(es) failing to sync: outlook HTTP_401, mailbox unknown (reconnect or check OAuth)",
  );
  assertEquals(
    mailboxErrorSummary([
      { mailbox_code: "a", provider: "gmail", code: "TOKEN_REFRESH_FAILED:invalid_client" },
      { mailbox_code: "b", provider: "outlook", code: "TOKEN_REFRESH_FAILED:invalid_grant" },
    ]),
    "gmail TOKEN_REFRESH_FAILED:invalid_client, outlook TOKEN_REFRESH_FAILED:invalid_grant " +
      "(check the OAuth client secret (reconnecting won't help); reconnect the mailbox)",
  );
});

Deno.test("Gmail mailbox and watch issues are skipped while Gmail alerts are off", () => {
  const h: OpsHealth = {
    mailbox_errors: [
      { mailbox_code: "mbx_g", provider: "gmail", code: "TOKEN_REFRESH_FAILED:invalid_grant" },
      { mailbox_code: "mbx_o", provider: "outlook", code: "HTTP_401" },
    ],
    mailboxes_stale: [{ mailbox_code: "mbx_g", provider: "gmail" }],
    gmail_watch_expiring: [{ mailbox_code: "mbx_g", provider: "gmail" }],
  };
  const off = evaluateHealth(h, { ...DEFAULT_THRESHOLDS, gmailAlerts: false });
  assertEquals(off.map((i) => i.issue), ["mailbox_errors"]);
  assertEquals((off[0].extra as { count: number }).count, 1);
  const on = evaluateHealth(h, { ...DEFAULT_THRESHOLDS, gmailAlerts: true });
  assertEquals(on.map((i) => i.issue).sort(), ["gmail_watch_expiring", "mailbox_errors", "mailboxes_stale"]);
});
