// Shared mailbox → document pipeline for gmail-push and outlook-poll.

import { storeDocument, validatePdf } from "./documents.ts";
import { type EmailRoute, normalizeEmail } from "./email_routes.ts";
import { HttpError, pgErrorToHttp } from "./http.ts";
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

export async function saveSyncState(
  svc: Db,
  mailbox: Mailbox,
  patch: Record<string, unknown>,
  extra: Record<string, unknown> = {},
): Promise<void> {
  const next = { ...(mailbox.sync_state ?? {}), ...patch, updated_at: new Date().toISOString() };
  const { error } = await svc.from("email_mailboxes").update({ sync_state: next, ...extra }).eq(
    "mailbox_code",
    mailbox.mailbox_code,
  );
  if (error) throw pgErrorToHttp(error, "could not save mailbox sync state");
  mailbox.sync_state = next;
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
 * Transient failures throw (the caller must not advance its cursor).
 */
export async function ingestAttachment(
  svc: Db,
  args: {
    mailbox: Mailbox;
    route: EmailRoute;
    messageId: string;
    attachmentKey: string;
    filename: string;
    download: () => Promise<Uint8Array>;
  },
): Promise<AttachmentOutcome> {
  const { mailbox, route } = args;
  if (await eventExists(svc, mailbox.profile_code, args.messageId, args.attachmentKey)) return "seen";

  const bytes = await args.download();
  let status: "ingested" | "duplicate" | "ignored";
  let docCode: string | null = null;
  let sha: string | null = null;
  let detail: string | null = null;
  try {
    validatePdf(bytes, args.filename);
    const r = await storeDocument(svc, {
      profileCode: mailbox.profile_code,
      bytes,
      filename: args.filename,
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
