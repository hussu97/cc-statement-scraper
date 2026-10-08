// gmail-push: per-mailbox processing, separate from index.ts so it can be tested with a
// fake Db and a fake fetch (_tests/gmail_push_test.ts).
//
// SRV-05: the run has a deadline (GMAIL_PUSH_BUDGET_MS), the cursor advances after
// every fully processed history page (to that page's last history record), history is
// filtered to the watch label when the watch has exactly one, and a 404 cursor reset
// (history older than Gmail keeps, about a week) is reported to Sentry and followed by a
// bounded messages.list backfill since the last successful sync.

import { captureMessage } from "../_shared/sentry.ts";
import { HttpError } from "../_shared/http.ts";
import type { Db } from "../_shared/supabase.ts";
import { mailboxAccessToken } from "../_shared/oauth.ts";
import { type EmailRoute, pickRoute, senderFromFromHeader } from "../_shared/email_routes.ts";
import { ingestAttachment, type Mailbox, mailboxRoutes, saveSyncState } from "../_shared/email_ingest.ts";
import { ProviderHttpError } from "../_shared/provider.ts";
import {
  GmailClient,
  headerMap,
  historyMessageIds,
  laterHistoryId,
  pageMaxHistoryId,
  pdfAttachmentStubs,
  watchLabels,
} from "../_shared/gmail.ts";

/** Default time budget per push: the Edge wall clock is 150 s, the Pub/Sub ack deadline 180 s. */
export const DEFAULT_GMAIL_PUSH_BUDGET_MS = 100_000;
/** Backfill after a cursor reset: at most this many messages.list pages of 100. */
export const MAX_BACKFILL_PAGES = 5;
/** Backfill window when the mailbox has never synced. */
const DEFAULT_BACKFILL_DAYS = 8;

export interface PushDeps {
  /** Epoch ms after which no new page or message is started. */
  deadline: number;
  fetchFn?: typeof fetch;
  now?: () => number;
}

export type MailboxStatus =
  | "ok"
  | "cursor_initialised"
  | "no_routes"
  | "cursor_reset"
  | "budget_exhausted";

export interface Counts {
  messages: number;
  ingested: number;
  duplicate: number;
  ignored: number;
  seen: number;
}

export interface MailboxResult extends Partial<Counts> {
  mailbox_code: string;
  status: MailboxStatus;
  backfill_complete?: boolean;
}

/**
 * Errors that redelivery cannot fix (SRV-19): a revoked or wrong OAuth grant, a mailbox
 * without a refresh token, missing OAuth configuration, or Gmail rejecting a freshly
 * minted token. They are recorded in sync_state.last_error and the push is acked.
 */
export function isPermanentMailboxError(e: unknown): boolean {
  if (e instanceof HttpError) {
    if (e.code === "MISCONFIGURED" || e.code === "MAILBOX_NOT_CONNECTED") return true;
    if (e.code === "TOKEN_REFRESH_FAILED") {
      return /\b(invalid_grant|invalid_client|unauthorized_client)\b/.test(e.message);
    }
    return e.status < 500;
  }
  if (e instanceof ProviderHttpError) return e.status === 400 || e.status === 401;
  return false;
}

export async function processMailbox(
  svc: Db,
  mb: Mailbox,
  pushedHistoryId: string | null,
  deps: PushDeps,
): Promise<MailboxResult> {
  const now = deps.now ?? Date.now;
  const fetchFn = deps.fetchFn ?? fetch;
  const syncedAt = new Date(now()).toISOString();
  const start = String(mb.sync_state?.gmail_history_id ?? "").trim();
  const routes = await mailboxRoutes(svc, mb.mailbox_code);

  if (!/^\d{1,30}$/.test(start) || routes.length === 0) {
    if (pushedHistoryId) {
      await saveSyncState(svc, mb, { gmail_history_id: pushedHistoryId, provider: "gmail", last_error: null }, {
        last_synced_at: syncedAt,
      });
    }
    return { mailbox_code: mb.mailbox_code, status: /^\d+$/.test(start) ? "no_routes" : "cursor_initialised" };
  }

  const { accessToken } = await mailboxAccessToken(svc, "gmail", mb.mailbox_code, fetchFn);
  const gmail = new GmailClient(accessToken, fetchFn);
  const labels = watchLabels(mb.sync_state);
  const labelId = labels.length === 1 ? labels[0] : null;
  const counts: Counts = { messages: 0, ingested: 0, duplicate: 0, ignored: 0, seen: 0 };
  const outOfTime = () => now() > deps.deadline;
  const handle = (id: string) => handleMessage(svc, gmail, mb, routes, id, counts);

  let mailboxHistoryId: string | null = null;
  let pageToken: string | undefined;
  do {
    if (outOfTime()) return { mailbox_code: mb.mailbox_code, status: "budget_exhausted", ...counts };
    let page;
    try {
      page = await gmail.historyPage(start, { pageToken, labelId });
    } catch (e) {
      if (e instanceof ProviderHttpError && e.status === 404) {
        return await resetCursor(svc, gmail, mb, pushedHistoryId, { labelId, counts, handle, outOfTime, now });
      }
      throw e;
    }
    for (const id of historyMessageIds(page)) {
      // Mid-page stop: this page's cursor isn't saved, and the redelivery skips the
      // messages already done through email_events.
      if (outOfTime()) return { mailbox_code: mb.mailbox_code, status: "budget_exhausted", ...counts };
      await handle(id);
    }
    const pageMax = pageMaxHistoryId(page);
    if (pageMax) await saveSyncState(svc, mb, { gmail_history_id: pageMax, provider: "gmail" });
    mailboxHistoryId = laterHistoryId(mailboxHistoryId, page.historyId);
    pageToken = page.nextPageToken || undefined;
  } while (pageToken);

  await saveSyncState(
    svc,
    mb,
    { gmail_history_id: laterHistoryId(mailboxHistoryId, pushedHistoryId), provider: "gmail", last_error: null },
    { last_synced_at: syncedAt },
  );
  return { mailbox_code: mb.mailbox_code, status: "ok", ...counts };
}

async function handleMessage(
  svc: Db,
  gmail: GmailClient,
  mb: Mailbox,
  routes: EmailRoute[],
  id: string,
  counts: Counts,
): Promise<void> {
  let msg;
  try {
    msg = await gmail.getMessage(id);
  } catch (e) {
    if (e instanceof ProviderHttpError && e.status === 404) return; // deleted since
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
      size: stub.size,
      download: () => gmail.getAttachment(id, stub.attachmentId),
    });
    counts[outcome]++;
  }
}

async function resetCursor(
  svc: Db,
  gmail: GmailClient,
  mb: Mailbox,
  pushedHistoryId: string | null,
  ctx: {
    labelId: string | null;
    counts: Counts;
    handle: (id: string) => Promise<void>;
    outOfTime: () => boolean;
    now: () => number;
  },
): Promise<MailboxResult> {
  const tags = { function: "gmail-push", mailbox_code: mb.mailbox_code, profile_code: mb.profile_code };
  captureMessage("gmail history cursor expired; resetting it with a bounded backfill", {
    level: "error",
    tags,
    fingerprint: ["gmail-push", "cursor_reset"],
  });
  const fresh = laterHistoryId(pushedHistoryId, await gmail.currentHistoryId());

  // Backfill: messages with attachments since a day before the last successful sync.
  const lastSync = Date.parse(mb.last_synced_at ?? "");
  const since = (Number.isFinite(lastSync) ? lastSync : ctx.now() - DEFAULT_BACKFILL_DAYS * 86_400_000) - 86_400_000;
  const query = `has:attachment after:${Math.floor(since / 1000)}`;
  let pageToken: string | undefined;
  let pages = 0;
  let complete = true;
  do {
    if (ctx.outOfTime() || pages >= MAX_BACKFILL_PAGES) {
      complete = false;
      break;
    }
    const page = await gmail.listMessages(query, { pageToken, labelIds: ctx.labelId ? [ctx.labelId] : [] });
    pages++;
    for (const m of page.messages ?? []) {
      if (ctx.outOfTime()) {
        complete = false;
        break;
      }
      const id = String(m?.id ?? "").trim();
      if (id) await ctx.handle(id);
    }
    pageToken = complete ? page.nextPageToken || undefined : undefined;
  } while (pageToken);
  if (!complete) {
    captureMessage("gmail backfill after a cursor reset did not finish; older mail may be missing", {
      level: "warning",
      tags,
      extra: { pages, messages: ctx.counts.messages },
      fingerprint: ["gmail-push", "backfill_incomplete"],
    });
  }
  await saveSyncState(
    svc,
    mb,
    {
      ...(fresh ? { gmail_history_id: fresh } : {}),
      provider: "gmail",
      cursor_reset_at: new Date(ctx.now()).toISOString(),
      last_error: null,
    },
    { last_synced_at: new Date(ctx.now()).toISOString() },
  );
  return { mailbox_code: mb.mailbox_code, status: "cursor_reset", backfill_complete: complete, ...ctx.counts };
}
