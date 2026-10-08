// Shared mailbox → document pipeline for gmail-push and outlook-poll.

import { prepareDocument, storeDocument } from "./documents.ts";
import { type EmailRoute, normalizeEmail } from "./email_routes.ts";
import { HttpError, pgErrorToHttp } from "./http.ts";
import { attachmentTooLarge, ProviderHttpError } from "./provider.ts";
import type { Db } from "./supabase.ts";

export interface Mailbox {
  mailbox_code: string;
  profile_code: string;
  provider: "gmail" | "outlook";
  mailbox_email: string;
  enabled: boolean;
  sync_state: Record<string, unknown>;
  watch_expires_at: string | null;
  last_synced_at: string | null;
}

export const MAILBOX_COLUMNS =
  "mailbox_code, profile_code, provider, mailbox_email, enabled, sync_state, watch_expires_at, last_synced_at";
export const ROUTE_COLUMNS =
  "route_code, profile_code, mailbox_code, bank_code, enabled, sender_allowlist, subject_keywords, attachment_filename_regex, gmail_label_filter";

export async function enabledMailboxes(svc: Db, provider: "gmail" | "outlook", email?: string): Promise<Mailbox[]> {
  const { data, error } = await svc.from("email_mailboxes").select(MAILBOX_COLUMNS).eq("provider", provider)
    .eq("enabled", true);
  if (error) throw pgErrorToHttp(error, "mailbox lookup failed");
  const rows = (data ?? []) as Mailbox[];
  return email ? rows.filter((m) => normalizeEmail(m.mailbox_email) === normalizeEmail(email)) : rows;
}

export async function mailboxRoutes(svc: Db, mailboxCode: string): Promise<EmailRoute[]> {
  const { data, error } = await svc.from("email_routes").select(ROUTE_COLUMNS).eq("mailbox_code", mailboxCode)
    .eq("enabled", true);
  if (error) throw pgErrorToHttp(error, "route lookup failed");
  return (data ?? []) as EmailRoute[];
}

export interface SyncColumns {
  last_synced_at?: string | null;
  watch_expires_at?: string | null;
}

/** PostgREST "function not found" (PGRST202) or Postgres undefined_function (42883). */
function rpcMissing(code: string | undefined): boolean {
  return code === "PGRST202" || code === "42883";
}

let warnedNoMergeRpc = false;

/**
 * Merge `patch` into the mailbox's sync_state (SRV-15). The database does the merge
 * (`merge_mailbox_sync_state`): keys not in the patch are kept and the Gmail cursor
 * only moves forward, so concurrent writers can't regress each other. `columns` sets
 * last_synced_at / watch_expires_at (null or absent = keep).
 *
 * If the RPC isn't deployed yet, falls back to the old snapshot write (one warning
 * per isolate) so a function deployed before its migration keeps working.
 */
export async function saveSyncState(
  svc: Db,
  mailbox: Mailbox,
  patch: Record<string, unknown>,
  columns: SyncColumns = {},
): Promise<void> {
  const { data, error } = await svc.rpc("merge_mailbox_sync_state", {
    p_mailbox_code: mailbox.mailbox_code,
    p_patch: patch,
    p_last_synced_at: columns.last_synced_at ?? null,
    p_watch_expires_at: columns.watch_expires_at ?? null,
  });
  if (!error) {
    if (data && typeof data === "object" && !Array.isArray(data)) mailbox.sync_state = data as Record<string, unknown>;
    return;
  }
  if (!rpcMissing(error.code)) throw pgErrorToHttp(error, "could not save mailbox sync state");

  if (!warnedNoMergeRpc) {
    console.warn("email_ingest: merge_mailbox_sync_state missing; falling back to a snapshot write");
    warnedNoMergeRpc = true;
  }
  const next = { ...(mailbox.sync_state ?? {}), ...patch, updated_at: new Date().toISOString() };
  const extra: Record<string, unknown> = {};
  if (columns.last_synced_at) extra.last_synced_at = columns.last_synced_at;
  if (columns.watch_expires_at) extra.watch_expires_at = columns.watch_expires_at;
  const { error: upErr } = await svc.from("email_mailboxes").update({ sync_state: next, ...extra }).eq(
    "mailbox_code",
    mailbox.mailbox_code,
  );
  if (upErr) throw pgErrorToHttp(upErr, "could not save mailbox sync state");
  mailbox.sync_state = next;
}

/**
 * Short, opaque error code for sync_state.last_error and Sentry tags: our HttpError
 * codes, `<PROVIDER>_<status>` for provider HTTP errors, never free text.
 */
export function mailboxErrorCode(e: unknown, provider: "gmail" | "outlook"): string {
  if (e instanceof HttpError) {
    // "gmail token refresh failed: HTTP 400 invalid_grant" → TOKEN_REFRESH_FAILED:invalid_grant
    const grant = /\b(invalid_grant|invalid_client|unauthorized_client)\b/.exec(e.message)?.[1];
    return grant ? `${e.code}:${grant}` : e.code;
  }
  if (e instanceof ProviderHttpError) return `${provider === "gmail" ? "GMAIL" : "GRAPH"}_${e.status}`;
  return "ERROR";
}

/** Record `last_error` on the mailbox (SRV-14) so the UI and ops_health can see it. Never throws. */
export async function recordMailboxError(svc: Db, mailbox: Mailbox, code: string): Promise<void> {
  await saveSyncState(svc, mailbox, { last_error: { at: new Date().toISOString(), code } }).catch(() => undefined);
}

export type AttachmentOutcome = "ingested" | "duplicate" | "ignored" | "seen";

async function eventExists(svc: Db, profileCode: string, messageId: string, attachmentKey: string): Promise<boolean> {
  const { data, error } = await svc.from("email_events").select("event_code").eq("profile_code", profileCode)
    .eq("provider_message_id", messageId).eq("provider_attachment_id", attachmentKey).maybeSingle();
  if (error) throw pgErrorToHttp(error, "email event lookup failed");
  return Boolean(data);
}

/**
 * Ingest one matched attachment. Idempotent per (profile, message, attachment):
 * an attachment that already has an email_events row is skipped without downloading.
 * One whose provider-reported `size` is over the 25 MB limit is recorded as ignored
 * without downloading it (SRV-07). Transient failures throw (the caller must not
 * advance its cursor).
 */
export async function ingestAttachment(
  svc: Db,
  args: {
    mailbox: Mailbox;
    route: EmailRoute;
    messageId: string;
    attachmentKey: string;
    filename: string;
    size?: number | null;
    download: () => Promise<Uint8Array>;
  },
): Promise<AttachmentOutcome> {
  const { mailbox, route } = args;
  if (await eventExists(svc, mailbox.profile_code, args.messageId, args.attachmentKey)) return "seen";

  let status: "ingested" | "duplicate" | "ignored";
  let docCode: string | null = null;
  let sha: string | null = null;
  let detail: string | null = null;
  try {
    if (attachmentTooLarge(args.size)) throw new HttpError(413, "FILE_TOO_LARGE", "attachment over the size limit");
    const document = await prepareDocument(await args.download(), args.filename);
    const r = await storeDocument(svc, {
      profileCode: mailbox.profile_code,
      document,
      source: mailbox.provider,
      sourceRef: `${args.messageId}/${args.attachmentKey}`.slice(0, 500),
      bankCodeHint: route.bank_code,
    });
    status = r.status === "queued" ? "ingested" : "duplicate";
    docCode = r.doc_code;
    sha = r.sha256;
  } catch (e) {
    if (e instanceof HttpError && e.status < 500) {
      status = "ignored";
      detail = e.code;
    } else {
      throw e;
    }
  }
  const { error } = await svc.from("email_events").insert({
    profile_code: mailbox.profile_code,
    route_code: route.route_code,
    provider_message_id: args.messageId,
    provider_attachment_id: args.attachmentKey,
    attachment_filename: args.filename.slice(0, 200),
    attachment_sha256: sha,
    status,
    doc_code: docCode,
    detail,
  });
  if (error && error.code !== "23505") throw pgErrorToHttp(error, "could not record email event");
  return status;
}
