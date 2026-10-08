// outlook-poll: Microsoft Graph delta polling for enabled outlook mailboxes, run by
// pg_cron hourly (x-cron-secret). Replaces backend/scripts/email_ingest_microsoft.py
// and its GitHub Actions cron.
//
// Per mailbox and folder (Inbox, DeletedItems, Archive): follow the stored delta
// cursor (or start a new delta limited to OUTLOOK_LOOKBACK_DAYS), match PDF
// attachments against the mailbox's routes, store them as documents (source
// 'outlook'). The cursor is saved after every page, so a run that hits the time
// budget resumes where it stopped. 410 → restart the delta; 404 → folder absent.

import { captureException, withSentry } from "../_shared/sentry.ts";
import { requireCron } from "../_shared/auth.ts";
import { HttpError, requireMethod } from "../_shared/http.ts";
import { runCronJob } from "../_shared/cron.ts";
import { type Db, serviceClient } from "../_shared/supabase.ts";
import { mailboxAccessToken } from "../_shared/oauth.ts";
import { pickRoute } from "../_shared/email_routes.ts";
import {
  enabledMailboxes,
  ingestAttachment,
  type Mailbox,
  mailboxRoutes,
  saveSyncState,
} from "../_shared/email_ingest.ts";
import { ProviderHttpError } from "../_shared/gmail.ts";
import {
  deltaKey,
  GraphClient,
  type GraphMessage,
  initialDeltaUrl,
  SCAN_FOLDERS,
  senderOf,
  storedCursor,
} from "./graph.ts";

async function pollMailbox(svc: Db, mb: Mailbox, deadline: number) {
  const routes = await mailboxRoutes(svc, mb.mailbox_code);
  if (routes.length === 0) return { mailbox_code: mb.mailbox_code, status: "no_routes" };
  const { accessToken } = await mailboxAccessToken(svc, "outlook", mb.mailbox_code);
  const graph = new GraphClient(accessToken);
  const lookback = Number(Deno.env.get("OUTLOOK_LOOKBACK_DAYS") ?? "90");
  const counts = { messages: 0, ingested: 0, duplicate: 0, ignored: 0, seen: 0 };
  let complete = true;

  for (const folder of SCAN_FOLDERS) {
    let url: string | null = storedCursor(mb.sync_state ?? {}, folder) ?? initialDeltaUrl(folder, lookback);
    let restarted = false;
    while (url) {
      if (Date.now() > deadline) {
        complete = false;
        break;
      }
      let page;
      try {
        page = await graph.get(url);
      } catch (e) {
        if (e instanceof ProviderHttpError && e.status === 410 && !restarted) {
          url = initialDeltaUrl(folder, lookback); // delta token expired
          restarted = true;
          continue;
        }
        if (e instanceof ProviderHttpError && e.status === 404) break; // folder doesn't exist
        throw e;
      }
      for (const m of (page.value ?? []) as GraphMessage[]) {
        if (!m?.id || m["@removed"] !== undefined || !m.hasAttachments) continue;
        counts.messages++;
        const attachments = await graph.listPdfAttachments(m.id);
        for (const a of attachments) {
          const filename = String(a.name ?? "").trim() || "statement.pdf";
          const route = pickRoute(routes, {
            sender: senderOf(m),
            subject: String(m.subject ?? ""),
            filename,
            labels: null,
          });
          if (!route) continue;
          const outcome = await ingestAttachment(svc, {
            mailbox: mb,
            route,
            messageId: m.id,
            attachmentKey: String(a.id),
            filename,
            download: () => graph.attachmentBytes(m.id!, String(a.id)),
          });
          counts[outcome]++;
        }
      }
      const next = typeof page["@odata.nextLink"] === "string" ? page["@odata.nextLink"] as string : null;
      const delta = typeof page["@odata.deltaLink"] === "string" ? page["@odata.deltaLink"] as string : null;
      // Persist progress after each page: nextLink mid-round, deltaLink at the end.
      await saveSyncState(svc, mb, { [deltaKey(folder)]: next ?? delta ?? url, provider: "outlook" });
      url = next;
    }
  }
  await saveSyncState(svc, mb, { last_error: null }, { last_synced_at: new Date().toISOString() });
  return { mailbox_code: mb.mailbox_code, status: complete ? "ok" : "budget_exhausted", ...counts };
}

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);
  return await runCronJob(req, "outlook-poll", pollAll);
}

async function pollAll() {
  const svc = serviceClient();
  const deadline = Date.now() + Number(Deno.env.get("OUTLOOK_BUDGET_MS") ?? "100000");
  const results = [];
  for (const mb of await enabledMailboxes(svc, "outlook")) {
    try {
      results.push(await pollMailbox(svc, mb, deadline));
    } catch (e) {
      const code = e instanceof HttpError ? e.code : e instanceof ProviderHttpError ? `GRAPH_${e.status}` : "ERROR";
      captureException(e, {
        tags: { function: "outlook-poll", mailbox_code: mb.mailbox_code, profile_code: mb.profile_code },
      });
      await saveSyncState(svc, mb, { last_error: { at: new Date().toISOString(), code } }).catch(() => undefined);
      results.push({ mailbox_code: mb.mailbox_code, status: "failed", error: code });
    }
  }
  return { results };
}

Deno.serve(withSentry("outlook-poll", handler));
