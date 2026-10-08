// Gmail API client and Pub/Sub push helpers. Ported from backend/scripts/gmail_ingest_relay.py.

import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "./deps.ts";
import { HttpError } from "./http.ts";
import { isPdfAttachment } from "./email_routes.ts";
import { decodeBase64Any, ProviderHttpError } from "./provider.ts";

export const GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me";
const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];

// ── Pub/Sub push authentication ─────────────────────────────────────────────

let _googleJwks: JWTVerifyGetKey | null = null;
function googleJwks(): JWTVerifyGetKey {
  if (!_googleJwks) _googleJwks = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));
  return _googleJwks;
}

/**
 * Verify the OIDC token Pub/Sub attaches to push requests: Google-signed, the
 * expected audience, and issued to the expected service account (email_verified).
 */
export async function verifyPushToken(
  token: string | null,
  opts: { audience: string; email: string; jwks?: JWTVerifyGetKey },
): Promise<void> {
  if (!opts.audience || !opts.email) {
    throw new HttpError(500, "MISCONFIGURED", "GMAIL_PUSH_AUDIENCE / GMAIL_PUSH_SA_EMAIL not set");
  }
  if (!token) throw new HttpError(401, "UNAUTHORIZED", "missing push token");
  let payload;
  try {
    ({ payload } = await jwtVerify(token, opts.jwks ?? googleJwks(), {
      issuer: GOOGLE_ISSUERS,
      audience: opts.audience,
      algorithms: ["RS256"],
      clockTolerance: 30,
    }));
  } catch {
    throw new HttpError(401, "UNAUTHORIZED", "invalid push token");
  }
  if (payload.email !== opts.email || payload.email_verified !== true) {
    throw new HttpError(403, "FORBIDDEN", "push token issued to an unexpected account");
  }
}

export interface PushNotification {
  emailAddress: string;
  historyId: string | null;
}

/** Decode a Pub/Sub push envelope carrying a Gmail watch notification. */
export function decodePubSubEnvelope(envelope: unknown): PushNotification {
  const msg = (envelope as { message?: { data?: unknown; attributes?: Record<string, unknown> } } | null)?.message;
  if (!msg || typeof msg !== "object") throw new HttpError(400, "INVALID_ENVELOPE", "missing Pub/Sub message");
  let payload: Record<string, unknown> = {};
  if (typeof msg.data === "string" && msg.data) {
    try {
      const parsed = JSON.parse(new TextDecoder().decode(decodeBase64Any(msg.data)));
      if (parsed && typeof parsed === "object") payload = parsed;
    } catch {
      throw new HttpError(400, "INVALID_ENVELOPE", "Pub/Sub data is not base64 JSON");
    }
  }
  const email = String(payload.emailAddress ?? msg.attributes?.emailAddress ?? "").trim();
  if (!email) throw new HttpError(400, "INVALID_ENVELOPE", "emailAddress missing");
  const hid = String(payload.historyId ?? "").trim();
  return { emailAddress: email, historyId: /^\d{1,30}$/.test(hid) ? hid : null };
}

// ── message structure helpers ───────────────────────────────────────────────

export interface GmailPart {
  partId?: string;
  filename?: string;
  mimeType?: string;
  body?: { attachmentId?: string; size?: number; data?: string };
  headers?: { name: string; value: string }[];
  parts?: GmailPart[];
}

export interface GmailMessage {
  id: string;
  labelIds?: string[];
  internalDate?: string;
  payload?: GmailPart;
}

export function headerMap(message: GmailMessage): Record<string, string> {
  const out: Record<string, string> = {};
  for (const h of message.payload?.headers ?? []) {
    const k = String(h?.name ?? "").trim().toLowerCase();
    if (k) out[k] = String(h?.value ?? "").trim();
  }
  return out;
}

export interface AttachmentStub {
  attachmentId: string;
  /** Stable per message (Gmail attachmentIds change between fetches; partIds don't). */
  key: string;
  filename: string;
  /** Decoded size in bytes as reported by Gmail, when known. */
  size: number | null;
}

export function pdfAttachmentStubs(message: GmailMessage): AttachmentStub[] {
  const out: AttachmentStub[] = [];
  const walk = (p: GmailPart | undefined) => {
    if (!p) return;
    const filename = String(p.filename ?? "").trim();
    const attachmentId = String(p.body?.attachmentId ?? "").trim();
    if (attachmentId && isPdfAttachment(filename, String(p.mimeType ?? ""))) {
      const size = Number(p.body?.size);
      out.push({
        attachmentId,
        key: p.partId ? `part:${p.partId}` : `att:${attachmentId.slice(0, 200)}`,
        filename: filename || "statement.pdf",
        size: Number.isFinite(size) && size >= 0 ? size : null,
      });
    }
    for (const c of p.parts ?? []) walk(c);
  };
  walk(message.payload);
  return out;
}

// ── API client ──────────────────────────────────────────────────────────────

export interface HistoryPage {
  history?: { id?: string; messagesAdded?: { message?: { id?: string } }[] }[];
  historyId?: string;
  nextPageToken?: string;
}

export class GmailClient {
  constructor(private accessToken: string, private fetchFn: typeof fetch = fetch) {}

  private async request(path: string, init: RequestInit = {}): Promise<Record<string, unknown>> {
    const res = await this.fetchFn(`${GMAIL_API}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${this.accessToken}`,
        Accept: "application/json",
        ...(init.body ? { "content-type": "application/json" } : {}),
      },
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) {
      await res.body?.cancel();
      throw new ProviderHttpError(res.status, `Gmail API HTTP ${res.status}`);
    }
    return await res.json();
  }

  /** One page of history (messageAdded), optionally limited to one label (SRV-05). */
  historyPage(startHistoryId: string, opts: { pageToken?: string; labelId?: string | null } = {}) {
    const q = new URLSearchParams({ startHistoryId, historyTypes: "messageAdded", maxResults: "100" });
    if (opts.labelId) q.set("labelId", opts.labelId);
    if (opts.pageToken) q.set("pageToken", opts.pageToken);
    return this.request(`/history?${q}`) as Promise<HistoryPage>;
  }

  /** One page of message ids matching a Gmail search (used for the bounded backfill). */
  listMessages(query: string, opts: { pageToken?: string; labelIds?: string[] } = {}) {
    const q = new URLSearchParams({ q: query, maxResults: "100" });
    for (const l of opts.labelIds ?? []) q.append("labelIds", l);
    if (opts.pageToken) q.set("pageToken", opts.pageToken);
    return this.request(`/messages?${q}`) as Promise<{ messages?: { id?: string }[]; nextPageToken?: string }>;
  }

  /** The mailbox's current history id (a fresh cursor when the pushed one is missing). */
  async currentHistoryId(): Promise<string | null> {
    const doc = await this.request("/profile");
    const id = String(doc.historyId ?? "");
    return /^\d+$/.test(id) ? id : null;
  }

  getMessage(id: string): Promise<GmailMessage> {
    return this.request(`/messages/${encodeURIComponent(id)}?format=full`) as unknown as Promise<GmailMessage>;
  }

  async getAttachment(messageId: string, attachmentId: string): Promise<Uint8Array> {
    const doc = await this.request(
      `/messages/${encodeURIComponent(messageId)}/attachments/${encodeURIComponent(attachmentId)}`,
    );
    return decodeBase64Any(String(doc.data ?? ""));
  }

  watch(topicName: string, labelIds: string[]) {
    return this.request("/watch", {
      method: "POST",
      body: JSON.stringify({ topicName, labelIds, labelFilterBehavior: "include" }),
    }) as Promise<{ historyId?: string; expiration?: string }>;
  }
}

/** Message ids added in a history page (deduped, order preserved). */
export function historyMessageIds(page: HistoryPage): string[] {
  const seen = new Set<string>();
  for (const h of page.history ?? []) {
    for (const a of h.messagesAdded ?? []) {
      const id = String(a?.message?.id ?? "").trim();
      if (id) seen.add(id);
    }
  }
  return [...seen];
}

/** Largest history record id in a page: every change up to it has been seen once the page is processed. */
export function pageMaxHistoryId(page: HistoryPage): string | null {
  let max: bigint | null = null;
  for (const h of page.history ?? []) {
    const id = String(h?.id ?? "");
    if (!/^\d{1,30}$/.test(id)) continue;
    const v = BigInt(id);
    if (max === null || v > max) max = v;
  }
  return max === null ? null : String(max);
}

/** The later of two numeric history ids (either may be missing). */
export function laterHistoryId(a: string | null | undefined, b: string | null | undefined): string | null {
  const ok = (s: string | null | undefined) => (s && /^\d{1,30}$/.test(s) ? BigInt(s) : null);
  const x = ok(a);
  const y = ok(b);
  if (x === null) return y === null ? null : String(y);
  if (y === null) return String(x);
  return String(x > y ? x : y);
}

/** The watch's labels (sync_state.watch_label_ids, default INBOX). */
export function watchLabels(syncState: Record<string, unknown> | null | undefined): string[] {
  const raw = syncState?.watch_label_ids;
  const labels = Array.isArray(raw) ? raw.map((x) => String(x).trim()).filter(Boolean) : [];
  return labels.length ? labels : ["INBOX"];
}
