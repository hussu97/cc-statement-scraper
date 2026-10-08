// member-invite (NEW-1): validation, same-origin redirects, owner checks, rate limits.

import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1.0.13";
import { HttpError } from "../_shared/http.ts";
import {
  type AuthAdmin,
  inviteError,
  type InviteRequest,
  RateLimiter,
  RESEND_COOLDOWN_MS,
  resolveRedirect,
  runInvite,
  validateInviteRequest,
} from "../member-invite/invite.ts";
import { FakeDb } from "./fake_db.ts";

const PRF = "prf_01k6zz0000000000000000000d";
const OWNER = "00000000-0000-0000-0000-00000000000a";

Deno.test("validateInviteRequest normalises and rejects bad input", () => {
  assertEquals(validateInviteRequest({ profile_code: PRF, email: " New@Example.COM " }), {
    profile_code: PRF,
    email: "new@example.com",
    role: "viewer",
    action: "invite",
    redirect_to: null,
  });
  const code = (b: unknown) => assertThrows(() => validateInviteRequest(b), HttpError).code;
  assertEquals(code({ profile_code: "prf_x", email: "a@b.co" }), "INVALID_PROFILE");
  assertEquals(code({ profile_code: PRF, email: "not-an-email" }), "INVALID_EMAIL");
  assertEquals(code({ profile_code: PRF, email: "a@b.co", role: "admin" }), "INVALID_ROLE");
  assertEquals(code({ profile_code: PRF, email: "a@b.co", action: "delete" }), "INVALID_ACTION");
});

Deno.test("resolveRedirect only allows the caller's own (allowed) origin", () => {
  const app = "https://ledger.example.app";
  assertEquals(resolveRedirect(app, null, [app]), `${app}/`);
  assertEquals(resolveRedirect(app, `${app}/settings?tab=members`, [app]), `${app}/settings?tab=members`);
  assertEquals(resolveRedirect(null, null, [app]), undefined, "iOS: no redirect, Auth uses the Site URL");
  assertEquals(resolveRedirect("http://127.0.0.1:5173", null, []), "http://127.0.0.1:5173/");
  const code = (o: string | null, r: string | null, allowed: string[]) =>
    assertThrows(() => resolveRedirect(o, r, allowed), HttpError).code;
  assertEquals(code(app, "https://evil.example/phish", [app]), "INVALID_REDIRECT");
  assertEquals(code(app, `https://user:pw@ledger.example.app/`, [app]), "INVALID_REDIRECT");
  assertEquals(code(app, "javascript:alert(1)", [app]), "INVALID_REDIRECT");
  assertEquals(code("https://evil.example", null, [app]), "ORIGIN_NOT_ALLOWED");
  assertEquals(code(null, `${app}/`, [app]), "INVALID_REDIRECT");
});

Deno.test("RateLimiter is a sliding window per key", () => {
  const l = new RateLimiter(2, 1000);
  assertEquals([l.take("a", 0), l.take("a", 10), l.take("a", 20), l.take("b", 20)], [true, true, false, true]);
  assertEquals(l.take("a", 1005), true, "the first hit left the window");
});

Deno.test("inviteError maps Auth errors without echoing them", () => {
  assertEquals(inviteError({ code: "email_exists", status: 422 }).code, "ALREADY_ACTIVE");
  assertEquals(inviteError({ status: 429 }).code, "EMAIL_RATE_LIMITED");
  assertEquals(
    inviteError({ status: 500, message: "smtp: secret host" }).message,
    "the invite email could not be sent",
  );
});

type User = { email_confirmed_at?: string | null; invited_at?: string | null; last_sign_in_at?: string | null };

function fakes(opts: {
  addResult?: string;
  addError?: { code: string; message: string };
  role?: string;
  members?: { user_id: string | null; email: string; role: string; pending: boolean }[];
  user?: User;
  inviteError?: { status?: number; code?: string };
  limit?: number;
}) {
  const db = new FakeDb({
    tables: { profile_members: opts.role ? [{ profile_code: PRF, user_id: OWNER, role: opts.role }] : [] },
    rpcs: {
      add_profile_member: () =>
        opts.addError ? { data: null, error: opts.addError } : { data: opts.addResult ?? "invited", error: null },
      list_profile_members: () => ({ data: opts.members ?? [], error: null }),
    },
  });
  const sent: { email: string; redirectTo?: string }[] = [];
  const admin: AuthAdmin = {
    inviteUserByEmail: (email, o) => {
      sent.push({ email, redirectTo: o?.redirectTo });
      return Promise.resolve({ data: null, error: opts.inviteError ?? null });
    },
    getUserById: () => Promise.resolve({ data: { user: opts.user ?? {} }, error: null }),
  };
  const deps = {
    user: db.asDb(),
    userId: OWNER,
    admin,
    limiter: new RateLimiter(opts.limit ?? 10, 3_600_000),
    redirectTo: "https://app.example/",
    now: () => Date.parse("2026-10-09T12:00:00Z"),
  };
  return { db, sent, deps };
}

const req = (over: Partial<InviteRequest> = {}): InviteRequest => ({
  profile_code: PRF,
  email: "new@example.com",
  role: "viewer",
  action: "invite",
  redirect_to: null,
  ...over,
});

Deno.test("invite: sends the Auth invite only when add_profile_member says invited", async () => {
  const f = fakes({ addResult: "invited" });
  assertEquals(await runInvite(req(), f.deps), { status: "invited", invite_sent: true });
  assertEquals(f.sent, [{ email: "new@example.com", redirectTo: "https://app.example/" }]);
  assertEquals(f.db.rpcCalls("add_profile_member"), [{
    p_profile_code: PRF,
    p_email: "new@example.com",
    p_role: "viewer",
  }]);

  const added = fakes({ addResult: "added" });
  assertEquals(await runInvite(req(), added.deps), { status: "added", invite_sent: false });
  assertEquals(added.sent.length, 0);
});

Deno.test("invite: a viewer is refused by add_profile_member's owner check", async () => {
  const f = fakes({ addError: { code: "42501", message: "not a owner of profile" } });
  const e = await assertRejects(() => runInvite(req(), f.deps), HttpError);
  assertEquals(e.status, 403);
  assertEquals(f.sent.length, 0);
});

Deno.test("invite: a failed email still adds the member and reports the code", async () => {
  const f = fakes({ inviteError: { status: 429 } });
  assertEquals(await runInvite(req(), f.deps), {
    status: "invited",
    invite_sent: false,
    invite_error: "EMAIL_RATE_LIMITED",
  });
});

Deno.test("invite: the per-caller limit applies before the member is added", async () => {
  const f = fakes({ limit: 1 });
  await runInvite(req(), f.deps);
  const e = await assertRejects(() => runInvite(req({ email: "two@example.com" }), f.deps), HttpError);
  assertEquals(e.code, "RATE_LIMITED");
  assertEquals(f.db.rpcCalls("add_profile_member").length, 1);
});

Deno.test("resend: owners only, members only, never to confirmed users, with a cooldown", async () => {
  const member = {
    user_id: "00000000-0000-0000-0000-00000000000b",
    email: "new@example.com",
    role: "viewer",
    pending: false,
  };
  const code = async (f: ReturnType<typeof fakes>) =>
    (await assertRejects(() => runInvite(req({ action: "resend" }), f.deps), HttpError)).code;

  assertEquals(await code(fakes({ role: "viewer", members: [member] })), "FORBIDDEN");
  assertEquals(await code(fakes({ role: "owner", members: [] })), "NOT_A_MEMBER");
  assertEquals(
    await code(fakes({ role: "owner", members: [member], user: { email_confirmed_at: "2026-10-01T00:00:00Z" } })),
    "ALREADY_ACTIVE",
  );
  assertEquals(
    await code(fakes({ role: "owner", members: [member], user: { invited_at: "2026-10-09T11:55:00Z" } })),
    "INVITE_COOLDOWN",
  );

  const ok = fakes({ role: "owner", members: [member], user: { invited_at: "2026-10-09T11:00:00Z" } });
  assertEquals(await runInvite(req({ action: "resend" }), ok.deps), { status: "resent", invite_sent: true });
  assertEquals(ok.sent.length, 1);

  const pending = fakes({ role: "owner", members: [{ ...member, user_id: null, pending: true }] });
  assertEquals(await runInvite(req({ action: "resend" }), pending.deps), { status: "resent", invite_sent: true });
  assertEquals(RESEND_COOLDOWN_MS, 600_000);
});
