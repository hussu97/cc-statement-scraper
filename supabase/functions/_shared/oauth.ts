// OAuth refresh-token → access-token for mailbox providers. Ported from
// backend/ccs_platform/api/v1/endpoints/email_ingestion.py (_provider_access_token).
// Client id/secret come from function secrets; the refresh token comes from Vault
// through the worker_mailbox_secret RPC (stored by set_mailbox_secret).

import { HttpError } from "./http.ts";
import type { Db } from "./supabase.ts";

export type Provider = "gmail" | "outlook";

export interface RefreshRequest {
  url: string;
  body: URLSearchParams;
}

export function buildRefreshRequest(
  provider: Provider,
  clientId: string,
  clientSecret: string,
  refreshToken: string,
  msTenant = "consumers",
): RefreshRequest {
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: clientId,
    client_secret: clientSecret,
    refresh_token: refreshToken,
  });
  if (provider === "outlook") {
    body.set("scope", "offline_access https://graph.microsoft.com/Mail.Read");
    return { url: `https://login.microsoftonline.com/${encodeURIComponent(msTenant)}/oauth2/v2.0/token`, body };
  }
  return { url: "https://oauth2.googleapis.com/token", body };
}

function clientCredentials(provider: Provider): { id: string; secret: string } {
  const prefix = provider === "gmail" ? "GMAIL" : "MS";
  const id = Deno.env.get(`${prefix}_OAUTH_CLIENT_ID`) ?? "";
  const secret = Deno.env.get(`${prefix}_OAUTH_CLIENT_SECRET`) ?? "";
  if (!id || !secret) {
    throw new HttpError(500, "MISCONFIGURED", `${prefix}_OAUTH_CLIENT_ID / ${prefix}_OAUTH_CLIENT_SECRET not set`);
  }
  return { id, secret };
}

export interface AccessToken {
  accessToken: string;
  expiresIn: number;
}

/** Exchange the mailbox's stored refresh token for an access token. */
export async function mailboxAccessToken(
  svc: Db,
  provider: Provider,
  mailboxCode: string,
  fetchFn: typeof fetch = fetch,
): Promise<AccessToken> {
  const { data: refresh, error } = await svc.rpc("worker_mailbox_secret", {
    p_mailbox_code: mailboxCode,
    p_key: "refresh_token",
  });
  if (error) throw new HttpError(500, "SECRET_READ_FAILED", "could not read mailbox refresh token");
  if (!refresh) throw new HttpError(409, "MAILBOX_NOT_CONNECTED", `mailbox ${mailboxCode} has no refresh token`);

  const { id, secret } = clientCredentials(provider);
  const req = buildRefreshRequest(
    provider,
    id,
    secret,
    String(refresh),
    Deno.env.get("MS_OAUTH_TENANT") || "consumers",
  );
  const res = await fetchFn(req.url, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: req.body,
    signal: AbortSignal.timeout(20_000),
  });
  const doc = await res.json().catch(() => ({}));
  if (!res.ok || !doc.access_token) {
    // Provider error codes only (e.g. invalid_grant) — never the response body as a whole.
    throw new HttpError(
      502,
      "TOKEN_REFRESH_FAILED",
      `${provider} token refresh failed: HTTP ${res.status} ${doc.error ?? ""}`,
    );
  }
  // Microsoft rotates refresh tokens; keep the newest one.
  if (doc.refresh_token && doc.refresh_token !== refresh) {
    await svc.rpc("set_mailbox_secret", {
      p_mailbox_code: mailboxCode,
      p_key: "refresh_token",
      p_value: doc.refresh_token,
    });
  }
  return { accessToken: String(doc.access_token), expiresIn: Number(doc.expires_in ?? 3600) };
}
