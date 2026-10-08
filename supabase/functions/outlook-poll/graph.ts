// Microsoft Graph helpers for outlook-poll (port of backend/scripts/email_ingest_microsoft.py).

import { ProviderHttpError } from "../_shared/gmail.ts";
import { isPdfAttachment } from "../_shared/email_routes.ts";

export const GRAPH = "https://graph.microsoft.com/v1.0";
export const SCAN_FOLDERS = ["Inbox", "DeletedItems", "Archive"] as const;

export interface GraphMessage {
  id?: string;
  subject?: string;
  hasAttachments?: boolean;
  receivedDateTime?: string;
  from?: { emailAddress?: { address?: string } };
  "@removed"?: unknown;
}

export interface GraphAttachment {
  id?: string;
  name?: string;
  contentType?: string;
  isInline?: boolean;
  contentBytes?: string;
}

/** sync_state key for a folder's delta cursor (same keys as the legacy script). */
export function deltaKey(folder: string): string {
  return `microsoft_delta_link_${folder.toLowerCase()}`;
}

/** Stored cursor for a folder, honouring the legacy single-key fallbacks for Inbox. */
export function storedCursor(syncState: Record<string, unknown>, folder: string): string | null {
  const v = syncState[deltaKey(folder)] ??
    (folder === "Inbox" ? (syncState.microsoft_delta_link ?? syncState.delta_link) : undefined);
  const s = typeof v === "string" ? v.trim() : "";
  return s.startsWith(GRAPH) ? s : null;
}

/** First delta URL for a folder, limited to the last `lookbackDays` of mail. */
export function initialDeltaUrl(folder: string, lookbackDays: number, now = new Date()): string {
  const since = new Date(now.getTime() - lookbackDays * 86_400_000).toISOString().replace(/\.\d{3}Z$/, "Z");
  // Encode spaces as %20 (not "+") — OData parses the raw query string.
  const q = [
    ["$select", "id,subject,from,hasAttachments,receivedDateTime"],
    ["$filter", `receivedDateTime ge ${since}`],
    ["$top", "50"],
  ].map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
  return `${GRAPH}/me/mailFolders/${encodeURIComponent(folder)}/messages/delta?${q}`;
}

export function senderOf(m: GraphMessage): string {
  return String(m.from?.emailAddress?.address ?? "");
}

export function pdfAttachments(values: GraphAttachment[]): GraphAttachment[] {
  return values.filter((a) =>
    a && !a.isInline && a.id && isPdfAttachment(String(a.name ?? ""), String(a.contentType ?? ""))
  );
}

export class GraphClient {
  constructor(private accessToken: string, private fetchFn: typeof fetch = fetch) {}

  async get(url: string): Promise<Record<string, unknown>> {
    if (!url.startsWith(GRAPH)) throw new Error("refusing to call a non-Graph URL");
    const res = await this.fetchFn(url, {
      headers: {
        Authorization: `Bearer ${this.accessToken}`,
        Accept: "application/json",
        Prefer: "odata.maxpagesize=50",
      },
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) {
      await res.body?.cancel();
      throw new ProviderHttpError(res.status, `Graph HTTP ${res.status}`);
    }
    return await res.json();
  }

  async listPdfAttachments(messageId: string): Promise<GraphAttachment[]> {
    const out: GraphAttachment[] = [];
    let url: string | null = `${GRAPH}/me/messages/${
      encodeURIComponent(messageId)
    }/attachments?$select=id,name,contentType,isInline,size`;
    while (url) {
      const page = await this.get(url);
      out.push(...pdfAttachments((page.value ?? []) as GraphAttachment[]));
      url = typeof page["@odata.nextLink"] === "string" ? page["@odata.nextLink"] as string : null;
    }
    return out;
  }

  async attachmentBytes(messageId: string, attachmentId: string): Promise<Uint8Array> {
    const doc = await this.get(
      `${GRAPH}/me/messages/${encodeURIComponent(messageId)}/attachments/${encodeURIComponent(attachmentId)}`,
    );
    const b64 = String(doc.contentBytes ?? "");
    if (!b64) return new Uint8Array();
    const bin = atob(b64);
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  }
}
