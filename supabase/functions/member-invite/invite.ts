// member-invite logic (NEW-1), separate from index.ts so it can be tested with fakes.
//
// Sign-ups are off, so a person added with add_profile_member who has no Auth user yet
// (status `invited`) can only get in through an Auth invite. This sends it:
//
//   action "invite" (default): add_profile_member through the caller's own client (its
//     owner check applies), then auth.admin.inviteUserByEmail when it returns `invited`.
//   action "resend": owner-only; re-sends the invite to a pending member of the profile.
//     Refused for active members and confirmed accounts.
//
// A pending invite attaches only when the address is confirmed (DB-23), so an invited
// person stays `pending` (with an unconfirmed Auth user) until they sign in.
//
// Abuse limits: per caller, at most INVITES_PER_HOUR sends per isolate (best effort);
// per address, no invite within RESEND_COOLDOWN_MS of the last one (durable: Auth's
// own `invited_at`); and Auth's email rate limit on top. The invite link redirects only
// to the caller's own web origin (same-origin and, when set, in ALLOWED_ORIGINS); Auth's
// redirect allow-list is the final check.

import { HttpError, pgErrorToHttp } from "../_shared/http.ts";
import type { Db } from "../_shared/supabase.ts";

export const INVITES_PER_HOUR = 10;
export const RESEND_COOLDOWN_MS = 10 * 60_000;
const PROFILE_RE = /^prf_[0-9a-z]{26}$/;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]+\.[^\s@]{2,}$/;

export interface InviteRequest {
  profile_code: string;
  email: string;
  role: "owner" | "viewer";
  action: "invite" | "resend";
  redirect_to: string | null;
}

export function validateInviteRequest(body: unknown): InviteRequest {
  const b = (body && typeof body === "object" ? body : {}) as Record<string, unknown>;
  const profile = String(b.profile_code ?? "").trim();
  if (!PROFILE_RE.test(profile)) throw new HttpError(422, "INVALID_PROFILE", "profile_code is not a profile code");
  const email = String(b.email ?? "").trim().toLowerCase();
  if (email.length > 254 || !EMAIL_RE.test(email)) throw new HttpError(422, "INVALID_EMAIL", "email is not valid");
  const role = String(b.role ?? "viewer");
  if (role !== "owner" && role !== "viewer") throw new HttpError(422, "INVALID_ROLE", "role must be owner or viewer");
  const action = String(b.action ?? "invite");
  if (action !== "invite" && action !== "resend") {
    throw new HttpError(422, "INVALID_ACTION", "action must be invite or resend");
  }
  const redirect = b.redirect_to == null || b.redirect_to === "" ? null : String(b.redirect_to);
  return { profile_code: profile, email, role, action, redirect_to: redirect };
}

/**
 * Where the invite link lands: `redirect_to` (or the caller's origin) only when it is the
 * request's own Origin, http(s), and in ALLOWED_ORIGINS when that is set. Without an
 * Origin header (the iOS app) no redirect is sent and Auth uses the project's Site URL.
 */
export function resolveRedirect(
  origin: string | null,
  redirectTo: string | null,
  allowedOrigins: string[],
): string | undefined {
  if (!origin) {
    if (redirectTo) throw new HttpError(422, "INVALID_REDIRECT", "redirect_to needs a same-origin browser request");
    return undefined;
  }
  let o: URL;
  try {
    o = new URL(origin);
  } catch {
    throw new HttpError(422, "INVALID_REDIRECT", "bad Origin header");
  }
  if (allowedOrigins.length > 0 && !allowedOrigins.includes(o.origin)) {
    throw new HttpError(403, "ORIGIN_NOT_ALLOWED", "this origin may not send invites");
  }
  if (!redirectTo) return `${o.origin}/`;
  let r: URL;
  try {
    r = new URL(redirectTo);
  } catch {
    throw new HttpError(422, "INVALID_REDIRECT", "redirect_to is not a URL");
  }
  if (!/^https?:$/.test(r.protocol) || r.origin !== o.origin || r.username || r.password) {
    throw new HttpError(422, "INVALID_REDIRECT", "redirect_to must be on the caller's own origin");
  }
  return r.href;
}

/** Sliding-window counter per key (per isolate: a best-effort first line of defence). */
export class RateLimiter {
  private hits = new Map<string, number[]>();
  constructor(private limit: number, private windowMs: number) {}

  take(key: string, now = Date.now()): boolean {
    const recent = (this.hits.get(key) ?? []).filter((t) => now - t < this.windowMs);
    if (recent.length >= this.limit) {
      this.hits.set(key, recent);
      return false;
    }
    recent.push(now);
    this.hits.set(key, recent);
    return true;
  }
}

/** An Auth user as auth.admin returns it (only the fields used here). */
export interface AuthUser {
  id: string;
  email?: string | null;
  email_confirmed_at?: string | null;
  invited_at?: string | null;
  last_sign_in_at?: string | null;
}

/** The slice of supabase-js `auth.admin` this function uses. */
export interface AuthAdmin {
  inviteUserByEmail(
    email: string,
    opts?: { redirectTo?: string },
  ): Promise<{ data: unknown; error: { status?: number; code?: string; message?: string } | null }>;
  listUsers(params: { page: number; perPage: number }): Promise<{
    data: { users: AuthUser[] } | null;
    error: { status?: number; code?: string } | null;
  }>;
}

export interface InviteDeps {
  /** The caller's own client (RLS and assert_member apply as the caller). */
  user: Db;
  userId: string;
  admin: AuthAdmin;
  limiter: RateLimiter;
  redirectTo: string | undefined;
  now?: () => number;
}

export type InviteOutcome =
  | { status: "added"; invite_sent: false }
  | { status: "invited" | "resent"; invite_sent: true }
  | { status: "invited"; invite_sent: false; invite_error: string };

/** Map an Auth invite error to an HttpError (never echoing its message). */
export function inviteError(err: { status?: number; code?: string; message?: string }): HttpError {
  if (err.code === "email_exists" || err.code === "user_already_exists" || err.status === 422) {
    return new HttpError(409, "ALREADY_ACTIVE", "this person already has an active account");
  }
  if (err.status === 429 || err.code === "over_email_send_rate_limit") {
    return new HttpError(429, "EMAIL_RATE_LIMITED", "too many emails sent; try again later");
  }
  return new HttpError(502, "INVITE_FAILED", "the invite email could not be sent");
}

const USERS_PER_PAGE = 200;
const MAX_USER_PAGES = 25;

/**
 * The Auth user with this email, if any. supabase-js has no lookup by email, so this
 * pages through auth.admin.listUsers (a household app has a handful of users).
 */
export async function findAuthUser(admin: AuthAdmin, email: string): Promise<AuthUser | null> {
  for (let page = 1; page <= MAX_USER_PAGES; page++) {
    const { data, error } = await admin.listUsers({ page, perPage: USERS_PER_PAGE });
    if (error) throw new HttpError(502, "INVITE_FAILED", "could not look up the account");
    const users = data?.users ?? [];
    const hit = users.find((u) => (u.email ?? "").toLowerCase() === email);
    if (hit) return hit;
    if (users.length < USERS_PER_PAGE) return null;
  }
  return null;
}

/**
 * Why an invite to this address must not be sent now, or null. Sign-ups are off and a
 * pending invite only attaches once the address is confirmed (DB-23), so an unconfirmed
 * Auth user is "invited, not accepted yet": it may get the invite again, but not within
 * RESEND_COOLDOWN_MS of the last one (Auth's own `invited_at`, so the limit is durable).
 */
export function inviteBlock(user: AuthUser | null, now: number): HttpError | null {
  if (!user) return null;
  if (user.email_confirmed_at) {
    return new HttpError(409, "ALREADY_ACTIVE", "this person already has an active account");
  }
  const last = Date.parse(user.invited_at ?? "");
  if (Number.isFinite(last) && now - last < RESEND_COOLDOWN_MS) {
    return new HttpError(429, "INVITE_COOLDOWN", "an invite was sent recently; try again in a few minutes");
  }
  return null;
}

function takeToken(deps: InviteDeps): void {
  if (!deps.limiter.take(deps.userId, (deps.now ?? Date.now)())) {
    throw new HttpError(429, "RATE_LIMITED", "too many invites; try again later");
  }
}

async function send(deps: InviteDeps, email: string): Promise<HttpError | null> {
  const { error } = await deps.admin.inviteUserByEmail(email, deps.redirectTo ? { redirectTo: deps.redirectTo } : {});
  return error ? inviteError(error) : null;
}

interface MemberRow {
  user_id: string | null;
  email: string | null;
  role: string;
  pending: boolean;
}

export async function runInvite(req: InviteRequest, deps: InviteDeps): Promise<InviteOutcome> {
  const now = (deps.now ?? Date.now)();
  if (req.action === "invite") {
    takeToken(deps); // before the add, so the limit also caps new pending members
    const { data, error } = await deps.user.rpc("add_profile_member", {
      p_profile_code: req.profile_code,
      p_email: req.email,
      p_role: req.role,
    });
    if (error) throw pgErrorToHttp(error, "could not add the member");
    if (data !== "invited") return { status: "added", invite_sent: false };
    // The member is pending either way; the owner can resend later.
    const failed = inviteBlock(await findAuthUser(deps.admin, req.email), now) ?? await send(deps, req.email);
    return failed
      ? { status: "invited", invite_sent: false, invite_error: failed.code }
      : { status: "invited", invite_sent: true };
  }

  // resend: owner only, and only to someone who is (or is pending as) a member.
  const { data: role, error: roleErr } = await deps.user.from("profile_members").select("role")
    .eq("profile_code", req.profile_code).eq("user_id", deps.userId).maybeSingle();
  if (roleErr) throw pgErrorToHttp(roleErr, "membership check failed");
  if (!role || role.role !== "owner") throw new HttpError(403, "FORBIDDEN", "not an owner of this profile");

  const { data: rows, error } = await deps.user.rpc("list_profile_members", { p_profile_code: req.profile_code });
  if (error) throw pgErrorToHttp(error, "could not list members");
  const member = ((rows ?? []) as MemberRow[]).find((m) => (m.email ?? "").toLowerCase() === req.email);
  if (!member) throw new HttpError(404, "NOT_A_MEMBER", "this email is not a member of the profile");
  if (!member.pending) throw new HttpError(409, "ALREADY_ACTIVE", "this person already has an active account");

  const blocked = inviteBlock(await findAuthUser(deps.admin, req.email), now);
  if (blocked) throw blocked;
  takeToken(deps);
  const failed = await send(deps, req.email);
  if (failed) throw failed;
  return { status: "resent", invite_sent: true };
}
