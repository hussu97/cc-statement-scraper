// gmail-push: Pub/Sub push endpoint for Gmail watch notifications. Ports
// backend/scripts/gmail_ingest_relay.py (the Cloud Run relay it replaces).
//
// Auth (verify_jwt=false): the Google-signed OIDC token Pub/Sub attaches
// (audience GMAIL_PUSH_AUDIENCE, service account GMAIL_PUSH_SA_EMAIL).
//
// Flow per enabled gmail mailbox matching the notification's emailAddress:
//   * no stored cursor  → store the pushed historyId and stop (first push after watch);
//   * history.list(messageAdded) from the stored cursor (404 → reset to pushed id);
//   * PDF attachments of each new message are matched against the mailbox's routes
//     and stored as documents (source 'gmail'), deduped by email_events + sha256;
//   * the cursor only advances after every page succeeded. Any failure returns 500
//     so Pub/Sub redelivers; redelivery is idempotent.

import { captureException, withSentry } from "../_shared/sentry.ts";
import { bearerToken } from "../_shared/auth.ts";
import { json, readJson, requireMethod } from "../_shared/http.ts";
import { type Db, serviceClient } from "../_shared/supabase.ts";
import { mailboxAccessToken } from "../_shared/oauth.ts";
import { pickRoute, senderFromFromHeader } from "../_shared/email_routes.ts";
import {
  enabledMailboxes,
  ingestAttachment,
  type Mailbox,
  mailboxRoutes,
  saveSyncState,
} from "../_shared/email_ingest.ts";
import {
  decodePubSubEnvelope,
  GmailClient,
  headerMap,
  historyMessageIds,
  pdfAttachmentStubs,
  ProviderHttpError,
  verifyPushToken,
} from "../_shared/gmail.ts";

function laterHistoryId(a: string | null | undefined, b: string | null | undefined): string | null {
  const x = a ? BigInt(a) : null;
  const y = b ? BigInt(b) : null;
  if (x === null) return y === null ? null : String(y);
  if (y === null) return String(x);
  return String(x > y ? x : y);
}

async function processMailbox(svc: Db, mb: Mailbox, pushedHistoryId: string | null) {
  const now = new Date().toISOString();
  const start = String(mb.sync_state?.gmail_history_id ?? "").trim();
  const routes = await mailboxRoutes(svc, mb.mailbox_code);

  if (!start || routes.length === 0) {
    if (pushedHistoryId) {
      await saveSyncState(svc, mb, { gmail_history_id: pushedHistoryId, provider: "gmail" }, { last_synced_at: now });
    }
    return { mailbox_code: mb.mailbox_code, status: start ? "no_routes" : "cursor_initialised" };
  }

  const { accessToken } = await mailboxAccessToken(svc, "gmail", mb.mailbox_code);
  const gmail = new GmailClient(accessToken);
  const counts = { messages: 0, ingested: 0, duplicate: 0, ignored: 0, seen: 0 };
  let latest: string | null = start;
  let pageToken: string | undefined;

  do {
    let page;
    try {
      page = await gmail.historyPage(start, pageToken);
    } catch (e) {
      if (e instanceof ProviderHttpError && e.status === 404) {
        // startHistoryId too old: Gmail only keeps about a week of history.
        await saveSyncState(svc, mb, { gmail_history_id: pushedHistoryId, provider: "gmail" }, { last_synced_at: now });
        return { mailbox_code: mb.mailbox_code, status: "cursor_reset" };
      }
      throw e;
    }
    for (const id of historyMessageIds(page)) {
      let msg;
      try {
        msg = await gmail.getMessage(id);
      } catch (e) {
        if (e instanceof ProviderHttpError && e.status === 404) continue; // deleted since
        throw e;
      }
      counts.messages++;
      const headers = headerMap(msg);
      const sender = senderFromFromHeader(headers.from ?? "");
      const subject = headers.subject ?? "";
      const labels = (msg.labelIds ?? []).map(String);
      for (const stub of pdfAttachmentStubs(msg)) {
        const route = pickRoute(routes, { sender, subject, filename: stub.filename, labels });
        if (!route) continue;
        const outcome = await ingestAttachment(svc, {
          mailbox: mb,
          route,
          messageId: id,
          attachmentKey: stub.key,
          filename: stub.filename,
          download: () => gmail.getAttachment(id, stub.attachmentId),
        });
        counts[outcome]++;
      }
    }
    latest = laterHistoryId(latest, page.historyId);
    pageToken = page.nextPageToken || undefined;
  } while (pageToken);

  await saveSyncState(
    svc,
    mb,
    { gmail_history_id: laterHistoryId(latest, pushedHistoryId), provider: "gmail" },
    { last_synced_at: now },
  );
  return { mailbox_code: mb.mailbox_code, status: "ok", ...counts };
}

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await verifyPushToken(bearerToken(req), {
    audience: Deno.env.get("GMAIL_PUSH_AUDIENCE") ?? "",
    email: Deno.env.get("GMAIL_PUSH_SA_EMAIL") ?? "",
  });
  const note = decodePubSubEnvelope(await readJson(req));
  const svc = serviceClient();
  const mailboxes = await enabledMailboxes(svc, "gmail", note.emailAddress);
  if (mailboxes.length === 0) return json({ status: "ignored", detail: "no enabled mailbox" }, 200, req);

  const results = [];
  let failed = 0;
  for (const mb of mailboxes) {
    try {
      results.push(await processMailbox(svc, mb, note.historyId));
    } catch (e) {
      failed++;
      captureException(e, { tags: { function: "gmail-push", mailbox_code: mb.mailbox_code, profile_code: mb.profile_code } });
      results.push({ mailbox_code: mb.mailbox_code, status: "failed" });
    }
  }
  // 500 makes Pub/Sub redeliver; processing is idempotent and the cursor didn't move.
  return json({ status: failed ? "partial_failure" : "ok", results }, failed ? 500 : 200, req);
}

Deno.serve(withSentry("gmail-push", handler));
