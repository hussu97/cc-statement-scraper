// outlook-poll: per-mailbox delta polling, separate from index.ts so it can be tested
// with a fake Db and a fake fetch (_tests/outlook_poll_test.ts).
//
// Per folder (Inbox, DeletedItems, Archive): follow the stored delta cursor (or start
// a new delta limited to `lookbackDays`), match PDF attachments against the routes,
// store them as documents (source 'outlook'). The cursor is saved after every page, so
// a run that hits the deadline resumes where it stopped. 410 → restart the delta once;
// 404 → the folder doesn't exist.

import type { Db } from "../_shared/supabase.ts";
import { mailboxAccessToken } from "../_shared/oauth.ts";
import { pickRoute } from "../_shared/email_routes.ts";
import { ingestAttachment, type Mailbox, mailboxRoutes, saveSyncState } from "../_shared/email_ingest.ts";
import { ProviderHttpError } from "../_shared/provider.ts";
import {
  deltaKey,
  GraphClient,
  type GraphMessage,
  initialDeltaUrl,
  SCAN_FOLDERS,
  senderOf,
  storedCursor,
} from "./graph.ts";

export interface PollDeps {
  /** Epoch ms after which no new page is started. */
  deadline: number;
  lookbackDays: number;
  fetchFn?: typeof fetch;
  now?: () => number;
}

export interface PollResult {
  mailbox_code: string;
  status: "ok" | "no_routes" | "budget_exhausted";
  messages?: number;
  ingested?: number;
  duplicate?: number;
  ignored?: number;
  seen?: number;
}

export async function pollMailbox(svc: Db, mb: Mailbox, deps: PollDeps): Promise<PollResult> {
  const now = deps.now ?? Date.now;
  const fetchFn = deps.fetchFn ?? fetch;
  const routes = await mailboxRoutes(svc, mb.mailbox_code);
  if (routes.length === 0) return { mailbox_code: mb.mailbox_code, status: "no_routes" };
  const { accessToken } = await mailboxAccessToken(svc, "outlook", mb.mailbox_code, fetchFn);
  const graph = new GraphClient(accessToken, fetchFn);
  const counts = { messages: 0, ingested: 0, duplicate: 0, ignored: 0, seen: 0 };
  let complete = true;

  for (const folder of SCAN_FOLDERS) {
    let url: string | null = storedCursor(mb.sync_state ?? {}, folder) ??
      initialDeltaUrl(folder, deps.lookbackDays, new Date(now()));
    let restarted = false;
    while (url) {
      if (now() > deps.deadline) {
        complete = false;
        break;
      }
      let page;
      try {
        page = await graph.get(url);
      } catch (e) {
        if (e instanceof ProviderHttpError && e.status === 410 && !restarted) {
          url = initialDeltaUrl(folder, deps.lookbackDays, new Date(now())); // delta token expired
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
            size: a.size ?? null,
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
    if (!complete) break;
  }
  await saveSyncState(svc, mb, { last_error: null }, { last_synced_at: new Date(now()).toISOString() });
  return { mailbox_code: mb.mailbox_code, status: complete ? "ok" : "budget_exhausted", ...counts };
}
