// Gmail API client and Pub/Sub push helpers. Ported from backend/scripts/gmail_ingest_relay.py.

import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "./deps.ts";
import { HttpError } from "./http.ts";
import { isPdfAttachment } from "./email_routes.ts";

export const GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me";
const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];

export class ProviderHttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "ProviderHttpError";
  }
}

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
      const bin = atob(msg.data.replace(/-/g, "+").replace(/_/g, "/"));
      const parsed = JSON.parse(new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0))));
      if (parsed && typeof parsed === "object") payload = parsed;
    } catch {
      throw new HttpError(400, "INVALID_ENVELOPE", "Pub/Sub data is not base64 JSON");
    }
  }
  const email = String(payload.emailAddress ?? msg.attributes?.emailAddress ?? "").trim();
  if (!email) throw new HttpError(400, "INVALID_ENVELOPE", "emailAddress missing");
  const hid = String(payload.historyId ?? "").trim();
  return { emailAddress: email, historyId: hid || null };
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
}

export function pdfAttachmentStubs(message: GmailMessage): AttachmentStub[] {
  const out: AttachmentStub[] = [];
  const walk = (p: GmailPart | undefined) => {
    if (!p) return;
    const filename = String(p.filename ?? "").trim();
    const attachmentId = String(p.body?.attachmentId ?? "").trim();
    if (attachmentId && isPdfAttachment(filename, String(p.mimeType ?? ""))) {
      out.push({
        attachmentId,
        key: p.partId ? `part:${p.partId}` : `att:${attachmentId.slice(0, 200)}`,
        filename: filename || "statement.pdf",
      });
    }
    for (const c of p.parts ?? []) walk(c);
  };
  walk(message.payload);
  return out;
}

export function base64UrlToBytes(data: string): Uint8Array {
  const b64 = data.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64 + "===".slice((b64.length + 3) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

// ── API client ──────────────────────────────────────────────────────────────

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

  /** One page of history (messageAdded). */
  historyPage(startHistoryId: string, pageToken?: string) {
    const q = new URLSearchParams({ startHistoryId, historyTypes: "messageAdded", maxResults: "100" });
    if (pageToken) q.set("pageToken", pageToken);
    return this.request(`/history?${q}`) as Promise<{
      history?: { messagesAdded?: { message?: { id?: string } }[] }[];
      historyId?: string;
      nextPageToken?: string;
    }>;
  }

  getMessage(id: string): Promise<GmailMessage> {
    return this.request(`/messages/${encodeURIComponent(id)}?format=full`) as unknown as Promise<GmailMessage>;
  }

  async getAttachment(messageId: string, attachmentId: string): Promise<Uint8Array> {
    const doc = await this.request(
      `/messages/${encodeURIComponent(messageId)}/attachments/${encodeURIComponent(attachmentId)}`,
    );
    const data = String(doc.data ?? "");
    return data ? base64UrlToBytes(data) : new Uint8Array();
  }

  watch(topicName: string, labelIds: string[]) {
    return this.request("/watch", {
      method: "POST",
      body: JSON.stringify({ topicName, labelIds, labelFilterBehavior: "include" }),
    }) as Promise<{ historyId?: string; expiration?: string }>;
  }
}

/** Message ids added in a history page (deduped, order preserved). */
export function historyMessageIds(page: { history?: { messagesAdded?: { message?: { id?: string } }[] }[] }): string[] {
  const seen = new Set<string>();
  for (const h of page.history ?? []) {
    for (const a of h.messagesAdded ?? []) {
      const id = String(a?.message?.id ?? "").trim();
      if (id) seen.add(id);
    }
  }
  return [...seen];
}
