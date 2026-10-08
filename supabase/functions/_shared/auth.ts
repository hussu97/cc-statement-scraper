// Caller authentication. Every function sets verify_jwt=false and authenticates here:
//   * user JWT (web / iOS)            → requireUser
//   * profile service token (scraper) → requireServiceToken  (RPC authenticate_service_token)
//   * pg_cron via pg_net              → requireCron          (x-cron-secret)

import { HttpError, pgErrorToHttp } from "./http.ts";
import { type Db, serviceClient, userClient } from "./supabase.ts";

export const SERVICE_TOKEN_PREFIX = "ccs_";

export function bearerToken(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(h.trim());
  return m ? m[1].trim() : null;
}

/** Service tokens are opaque `ccs_<hex>` strings; anything else is treated as a JWT. */
export function isServiceToken(token: string): boolean {
  return token.startsWith(SERVICE_TOKEN_PREFIX);
}

export interface UserCaller {
  kind: "user";
  userId: string;
  jwt: string;
  client: Db;
}

export interface TokenCaller {
  kind: "token";
  profileCode: string;
}

export type Caller = UserCaller | TokenCaller;

export async function requireUser(req: Request): Promise<UserCaller> {
  const jwt = bearerToken(req);
  if (!jwt || isServiceToken(jwt)) throw new HttpError(401, "UNAUTHORIZED", "sign-in required");
  const { data, error } = await serviceClient().auth.getUser(jwt);
  if (error || !data?.user) throw new HttpError(401, "UNAUTHORIZED", "invalid or expired session");
  return { kind: "user", userId: data.user.id, jwt, client: userClient(jwt) };
}

export async function requireServiceToken(req: Request, scope: string): Promise<TokenCaller> {
  const token = bearerToken(req);
  if (!token || !isServiceToken(token)) throw new HttpError(401, "UNAUTHORIZED", "service token required");
  const profileKey = req.headers.get("x-profile-key")?.trim() || null;
  const { data, error } = await serviceClient().rpc("authenticate_service_token", {
    p_token: token,
    p_scope: scope,
    p_profile_key: profileKey,
  });
  if (error) {
    const e = pgErrorToHttp(error, "token check failed");
    // Never echo token details back; 28000 → 401 with a fixed message.
    if (e.status === 401) throw new HttpError(401, "UNAUTHORIZED", "invalid service token, scope or profile key");
    throw e;
  }
  if (typeof data !== "string" || !data) throw new HttpError(401, "UNAUTHORIZED", "invalid service token");
  return { kind: "token", profileCode: data };
}

/** Accept either a user JWT or a service token carrying `scope`. */
export function requireUserOrServiceToken(req: Request, scope: string): Promise<Caller> {
  const token = bearerToken(req);
  if (token && isServiceToken(token)) return requireServiceToken(req, scope);
  return requireUser(req);
}

/** Owner check through the user's own client (RLS: members can read their profile's members). */
export async function assertOwner(caller: UserCaller, profileCode: string): Promise<void> {
  const { data, error } = await caller.client
    .from("profile_members")
    .select("role")
    .eq("profile_code", profileCode)
    .eq("user_id", caller.userId)
    .maybeSingle();
  if (error) throw pgErrorToHttp(error, "membership check failed");
  if (!data || data.role !== "owner") throw new HttpError(403, "FORBIDDEN", "not an owner of this profile");
}

const enc = new TextEncoder();

/** Constant-time string comparison (hash both sides so length leaks nothing). */
export async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const x = new Uint8Array(ha);
  const y = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0 && a.length === b.length;
}

/** pg_cron → pg_net calls carry `x-cron-secret` (see private.invoke_edge). Fails closed. */
export async function requireCron(req: Request, secret = Deno.env.get("CRON_SECRET") ?? ""): Promise<void> {
  const given = req.headers.get("x-cron-secret") ?? "";
  if (!secret) throw new HttpError(500, "MISCONFIGURED", "CRON_SECRET is not configured");
  if (!given || !(await timingSafeEqual(given, secret))) {
    throw new HttpError(401, "UNAUTHORIZED", "invalid cron secret");
  }
}
