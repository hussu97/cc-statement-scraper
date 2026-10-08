// gmail-watch-renew: renew the Gmail users.watch for every enabled gmail mailbox
// (watches expire after 7 days). pg_cron calls it daily with x-cron-secret.
//
// The topic is GMAIL_PUBSUB_TOPIC (projects/<p>/topics/<t>); label ids come from
// sync_state.watch_label_ids, default ["INBOX"]. Also seeds the history cursor from
// the watch response when a mailbox has none yet.

import { captureException, withSentry } from "../_shared/sentry.ts";
import { requireCron } from "../_shared/auth.ts";
import { HttpError, requireMethod } from "../_shared/http.ts";
import { runCronJob } from "../_shared/cron.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { mailboxAccessToken } from "../_shared/oauth.ts";
import { enabledMailboxes, mailboxErrorCode, recordMailboxError, saveSyncState } from "../_shared/email_ingest.ts";
import { GmailClient, watchLabels } from "../_shared/gmail.ts";

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);
  const topic = Deno.env.get("GMAIL_PUBSUB_TOPIC") ?? "";
  if (!topic) throw new HttpError(500, "MISCONFIGURED", "GMAIL_PUBSUB_TOPIC not set");
  return await runCronJob(req, "gmail-watch-renew", () => renewAll(topic));
}

async function renewAll(topic: string) {
  const svc = serviceClient();
  const renewed = [];
  const failed = [];
  for (const mb of await enabledMailboxes(svc, "gmail")) {
    try {
      const { accessToken } = await mailboxAccessToken(svc, "gmail", mb.mailbox_code);
      const res = await new GmailClient(accessToken).watch(topic, watchLabels(mb.sync_state));
      const exp = /^\d+$/.test(String(res.expiration ?? "")) ? new Date(Number(res.expiration)).toISOString() : null;
      // last_error is cleared here: a renewed watch proves the grant works (SRV-14).
      const patch: Record<string, unknown> = { provider: "gmail", last_error: null };
      if (!mb.sync_state?.gmail_history_id && res.historyId) patch.gmail_history_id = String(res.historyId);
      await saveSyncState(svc, mb, patch, { watch_expires_at: exp });
      renewed.push({ mailbox_code: mb.mailbox_code, watch_expires_at: exp });
    } catch (e) {
      const code = mailboxErrorCode(e, "gmail");
      captureException(e, {
        tags: { function: "gmail-watch-renew", mailbox_code: mb.mailbox_code, profile_code: mb.profile_code },
      });
      await recordMailboxError(svc, mb, code);
      failed.push({ mailbox_code: mb.mailbox_code, error: code });
    }
  }
  return { renewed, failed };
}

Deno.serve(withSentry("gmail-watch-renew", handler));
