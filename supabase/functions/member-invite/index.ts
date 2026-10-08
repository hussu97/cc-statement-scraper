// member-invite (NEW-1): add a member and send the Auth invite email, or resend it.
//
// Auth (verify_jwt=false; checked here): a user JWT. Owner-only: add_profile_member runs
// through the caller's own client (assert_member(owner) applies) and "resend" checks
// ownership first. The service-role client is used only afterwards, for
// auth.admin.inviteUserByEmail / listUsers. Logic and limits: invite.ts.
//
// Body: {profile_code, email, role?: "viewer"|"owner", action?: "invite"|"resend", redirect_to?}
// Response 200: {status: "added"|"invited"|"resent", invite_sent: boolean, invite_error?: code}
// Errors: 401, 403 (not an owner / origin not allowed), 404 NOT_A_MEMBER, 409 ALREADY_ACTIVE,
//         422 (validation), 429 RATE_LIMITED / INVITE_COOLDOWN / EMAIL_RATE_LIMITED, 502 INVITE_FAILED.

import { withSentry } from "../_shared/sentry.ts";
import { requireUser } from "../_shared/auth.ts";
import { json, readJson, requireMethod } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import {
  type AuthAdmin,
  INVITES_PER_HOUR,
  RateLimiter,
  resolveRedirect,
  runInvite,
  validateInviteRequest,
} from "./invite.ts";

const limiter = new RateLimiter(INVITES_PER_HOUR, 3_600_000);

function allowedOrigins(): string[] {
  return (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
}

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  const caller = await requireUser(req);
  const body = validateInviteRequest(await readJson(req, 10_000));
  const redirectTo = resolveRedirect(req.headers.get("origin"), body.redirect_to, allowedOrigins());
  const outcome = await runInvite(body, {
    user: caller.client,
    userId: caller.userId,
    admin: serviceClient().auth.admin as unknown as AuthAdmin,
    limiter,
    redirectTo,
  });
  return json(outcome, 200, req);
}

Deno.serve(withSentry("member-invite", handler));
