// outlook-poll: Microsoft Graph delta polling for enabled outlook mailboxes, run by
// pg_cron hourly (x-cron-secret). Replaces backend/scripts/email_ingest_microsoft.py
// and its GitHub Actions cron. The per-mailbox work is in poll.ts.

import { captureException, withSentry } from "../_shared/sentry.ts";
import { requireCron } from "../_shared/auth.ts";
import { requireMethod } from "../_shared/http.ts";
import { runCronJob } from "../_shared/cron.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { enabledMailboxes, mailboxErrorCode, recordMailboxError } from "../_shared/email_ingest.ts";
import { pollMailbox } from "./poll.ts";

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);
  return await runCronJob(req, "outlook-poll", pollAll);
}

async function pollAll() {
  const svc = serviceClient();
  const deadline = Date.now() + Number(Deno.env.get("OUTLOOK_BUDGET_MS") ?? "100000");
  const lookbackDays = Number(Deno.env.get("OUTLOOK_LOOKBACK_DAYS") ?? "90");
  const results = [];
  for (const mb of await enabledMailboxes(svc, "outlook")) {
    try {
      results.push(await pollMailbox(svc, mb, { deadline, lookbackDays }));
    } catch (e) {
      const code = mailboxErrorCode(e, "outlook");
      captureException(e, {
        tags: { function: "outlook-poll", mailbox_code: mb.mailbox_code, profile_code: mb.profile_code },
      });
      await recordMailboxError(svc, mb, code);
      results.push({ mailbox_code: mb.mailbox_code, status: "failed", error: code });
    }
  }
  return { results };
}

Deno.serve(withSentry("outlook-poll", handler));
