// gmail-push: Pub/Sub push endpoint for Gmail watch notifications. Ports
// backend/scripts/gmail_ingest_relay.py (the Cloud Run relay it replaces).
//
// Auth (verify_jwt=false): the Google-signed OIDC token Pub/Sub attaches
// (audience GMAIL_PUSH_AUDIENCE, service account GMAIL_PUSH_SA_EMAIL).
//
// Flow per enabled gmail mailbox matching the notification's emailAddress
// (gmail-push/process.ts):
//   * no stored cursor  → store the pushed historyId and stop (first push after watch);
//   * history.list(messageAdded, the watch label) from the stored cursor; the cursor
//     advances after every page, so a backlog makes progress across deliveries;
//   * 404 (cursor older than Gmail's history) → Sentry error, bounded backfill, reset;
//   * PDF attachments of each new message are matched against the mailbox's routes
//     and stored as documents (source 'gmail'), deduped by email_events + sha256.
//
// Responses (Pub/Sub acks only 2xx):
//   200  done, nothing to do, or only permanent failures (bad envelope, revoked grant,
//        missing OAuth config): recorded in sync_state.last_error and acked (SRV-19);
//   503  the time budget ran out: redelivery continues from the saved cursor;
//   500  a transient failure: redelivery retries (idempotent). After 10 deliveries the
//        subscription dead-letters the message (PRODUCTION.md §5).

import { captureException, captureMessage, withSentry } from "../_shared/sentry.ts";
import { bearerToken } from "../_shared/auth.ts";
import { HttpError, json, readJson, requireMethod } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { enabledMailboxes, mailboxErrorCode, recordMailboxError } from "../_shared/email_ingest.ts";
import { decodePubSubEnvelope, type PushNotification, verifyPushToken } from "../_shared/gmail.ts";
import {
  DEFAULT_GMAIL_PUSH_BUDGET_MS,
  isPermanentMailboxError,
  type MailboxResult,
  processMailbox,
} from "./process.ts";

async function handler(req: Request): Promise<Response> {
  const startedAt = Date.now();
  requireMethod(req, "POST");
  await verifyPushToken(bearerToken(req), {
    audience: Deno.env.get("GMAIL_PUSH_AUDIENCE") ?? "",
    email: Deno.env.get("GMAIL_PUSH_SA_EMAIL") ?? "",
  });

  let note: PushNotification;
  try {
    note = decodePubSubEnvelope(await readJson(req));
  } catch (e) {
    // An authenticated but malformed envelope never gets better on redelivery: ack it.
    if (e instanceof HttpError && e.status === 400) {
      captureMessage("gmail-push: malformed Pub/Sub envelope acked", {
        level: "warning",
        tags: { function: "gmail-push", error_code: e.code },
        fingerprint: ["gmail-push", "invalid_envelope"],
      });
      return json({ status: "ignored", detail: e.code }, 200, req);
    }
    throw e;
  }

  const svc = serviceClient();
  const mailboxes = await enabledMailboxes(svc, "gmail", note.emailAddress);
  if (mailboxes.length === 0) return json({ status: "ignored", detail: "no enabled mailbox" }, 200, req);

  const budget = Number(Deno.env.get("GMAIL_PUSH_BUDGET_MS") ?? DEFAULT_GMAIL_PUSH_BUDGET_MS);
  const deadline = startedAt + (Number.isFinite(budget) && budget > 0 ? budget : DEFAULT_GMAIL_PUSH_BUDGET_MS);
  const results: (MailboxResult | { mailbox_code: string; status: "failed"; error: string; permanent: boolean })[] = [];
  let transient = 0;
  for (const mb of mailboxes) {
    try {
      results.push(await processMailbox(svc, mb, note.historyId, { deadline }));
    } catch (e) {
      const code = mailboxErrorCode(e, "gmail");
      const permanent = isPermanentMailboxError(e);
      const tags = { function: "gmail-push", mailbox_code: mb.mailbox_code, profile_code: mb.profile_code };
      await recordMailboxError(svc, mb, code);
      if (permanent) {
        captureMessage(`gmail-push: mailbox needs attention (${code})`, {
          level: "warning",
          tags: { ...tags, error_code: code },
          fingerprint: ["gmail-push", "permanent", code],
        });
      } else {
        transient++;
        captureException(e, { tags });
      }
      results.push({ mailbox_code: mb.mailbox_code, status: "failed", error: code, permanent });
    }
  }
  const exhausted = results.some((r) => r.status === "budget_exhausted");
  const status = transient ? 500 : exhausted ? 503 : 200;
  const summary = transient ? "partial_failure" : exhausted ? "budget_exhausted" : "ok";
  return json({ status: summary, results }, status, req);
}

Deno.serve(withSentry("gmail-push", handler));
