import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { keys } from "./keys";
import { ApiError, functionError, must, mustList } from "./api";

/**
 * For a mutation whose variables or result carry a secret (a new token's
 * plaintext, a PDF password, a refresh token): drop it from the
 * MutationCache as soon as no component watches it, instead of keeping it
 * for the default 5 minutes (WEB-50).
 */
export const SECRET_MUTATION = { gcTime: 0 } as const;

// ── members ────────────────────────────────────────────────────────────────
/** A row of list_profile_members: a member, or a pending invite (user_id null). */
export interface ProfileMember {
  user_id: string | null;
  email: string | null;
  role: "owner" | "viewer";
  created_at: string;
  pending: boolean;
}

export function useMembers(profileCode: string) {
  return useQuery({
    queryKey: keys.members(profileCode),
    queryFn: async () =>
      mustList(await supabase.rpc("list_profile_members", { p_profile_code: profileCode })) as unknown as ProfileMember[],
  });
}

/** What the `member-invite` Edge Function answers (`supabase/functions/member-invite`). */
export interface MemberInviteResult {
  status: "added" | "invited" | "resent";
  invite_sent: boolean;
  /** Why the email was not sent although the member was saved (`INVITE_COOLDOWN`, ...). */
  invite_error?: string;
}

async function memberInvite(body: {
  profile_code: string;
  email: string;
  role?: "owner" | "viewer";
  action: "invite" | "resend";
}): Promise<MemberInviteResult> {
  const { data, error } = await supabase.functions.invoke<MemberInviteResult>("member-invite", { body });
  if (error) throw await functionError(error);
  if (!data) throw new ApiError("The server sent an empty answer. Refresh to check the list.");
  return data;
}

/**
 * Add a member, and email an invite when they have no account yet (NEW-1r). The
 * function adds through add_profile_member as the caller, then sends the Auth invite.
 */
export function useInviteMember(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { email: string; role: "owner" | "viewer" }) =>
      memberInvite({ profile_code: profileCode, email: v.email.trim(), role: v.role, action: "invite" }),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.members(profileCode) }),
  });
}

/** Email the invite again to a pending member. The variable is their email. */
export function useResendInvite(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (email: string) => memberInvite({ profile_code: profileCode, email, action: "resend" }),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.members(profileCode) }),
  });
}

export function useRemoveMember(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (userId: string) =>
      must(await supabase.rpc("remove_profile_member", { p_profile_code: profileCode, p_user_id: userId })),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.members(profileCode) }),
  });
}

export function useCancelInvite(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (email: string) =>
      must(await supabase.rpc("cancel_profile_invite", { p_profile_code: profileCode, p_email: email })),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.members(profileCode) }),
  });
}

export function useRenameProfile(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (name: string) => must(await supabase.from("profiles").update({ name: name.trim() }).eq("profile_code", profileCode)),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.profiles }),
  });
}

// ── service tokens ─────────────────────────────────────────────────────────
export const TOKEN_SCOPES = [
  { value: "statements:upload", label: "Upload statements (scraper)" },
  { value: "sms:ingest", label: "Send bank SMS" },
] as const;

export function useServiceTokens(profileCode: string) {
  return useQuery({
    queryKey: keys.tokens(profileCode),
    queryFn: async () =>
      mustList(
        await supabase
          .from("service_tokens")
          .select("token_code, name, token_prefix, scopes, created_at, last_used_at, revoked_at")
          .eq("profile_code", profileCode)
          .order("created_at", { ascending: false }),
      ),
  });
}

export function useCreateServiceToken(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    ...SECRET_MUTATION,
    mutationFn: async (v: { name: string; scopes: string[] }) =>
      must(await supabase.rpc("create_service_token", { p_profile_code: profileCode, p_name: v.name.trim(), p_scopes: v.scopes })) as unknown as {
        token_code: string;
        token: string;
      },
    onSettled: () => qc.invalidateQueries({ queryKey: keys.tokens(profileCode) }),
  });
}

export function useRevokeServiceToken(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (tokenCode: string) => must(await supabase.rpc("revoke_service_token", { p_token_code: tokenCode })),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.tokens(profileCode) }),
  });
}

// ── PDF passwords (Vault) ──────────────────────────────────────────────────
export const SECRET_KEYS = [
  { key: "ADCB_PDF_PASSWORD", label: "ADCB statement password" },
  { key: "ADCB_CID", label: "ADCB customer ID (CID)" },
  { key: "FAB_PDF_PASSWORD", label: "FAB statement password" },
  { key: "ENBD_PDF_PASSWORD", label: "Emirates NBD statement password" },
  { key: "EIB_PDF_PASSWORD", label: "Emirates Islamic statement password" },
  { key: "SIB_PDF_PASSWORD", label: "Sharjah Islamic statement password" },
  { key: "MASHREQ_PDF_PASSWORD", label: "Mashreq statement password" },
] as const;

export function useProfileSecrets(profileCode: string) {
  return useQuery({
    queryKey: keys.secrets(profileCode),
    queryFn: async () => mustList(await supabase.rpc("list_profile_secrets", { p_profile_code: profileCode })),
  });
}

export function useSetProfileSecret(profileCode: string) {
  const qc = useQueryClient();
  return useMutation({
    ...SECRET_MUTATION,
    mutationFn: async (v: { key: string; value: string }) =>
      must(await supabase.rpc("set_profile_secret", { p_profile_code: profileCode, p_key: v.key, p_value: v.value })),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.secrets(profileCode) }),
  });
}

// ── email ingestion ────────────────────────────────────────────────────────
export function useMailboxes(profileCode: string) {
  return useQuery({
    queryKey: keys.mailboxes(profileCode),
    queryFn: async () => {
      const [mbx, routes, events] = await Promise.all([
        supabase.from("email_mailboxes").select("*").eq("profile_code", profileCode).order("created_at"),
        supabase.from("email_routes").select("*").eq("profile_code", profileCode).order("bank_code"),
        supabase
          .from("email_events")
          .select("event_code, route_code, attachment_filename, status, doc_code, detail, created_at")
          .eq("profile_code", profileCode)
          .order("created_at", { ascending: false })
          .limit(20),
      ]);
      return { mailboxes: mustList(mbx), routes: mustList(routes), events: mustList(events) };
    },
  });
}

function useInvalidateMail(profileCode: string) {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ queryKey: keys.mailboxes(profileCode) });
}

export function useAddMailbox(profileCode: string) {
  const invalidate = useInvalidateMail(profileCode);
  return useMutation({
    mutationFn: async (v: { provider: "gmail" | "outlook"; email: string }) =>
      must(await supabase.from("email_mailboxes").insert({ profile_code: profileCode, provider: v.provider, mailbox_email: v.email.trim() })),
    onSettled: invalidate,
  });
}

export function useToggleMailbox(profileCode: string) {
  const invalidate = useInvalidateMail(profileCode);
  return useMutation({
    mutationFn: async (v: { mailboxCode: string; enabled: boolean }) =>
      must(await supabase.from("email_mailboxes").update({ enabled: v.enabled }).eq("mailbox_code", v.mailboxCode)),
    onSettled: invalidate,
  });
}

export function useDeleteMailbox(profileCode: string) {
  const invalidate = useInvalidateMail(profileCode);
  return useMutation({
    mutationFn: async (mailboxCode: string) => must(await supabase.from("email_mailboxes").delete().eq("mailbox_code", mailboxCode)),
    onSettled: invalidate,
  });
}

export interface RouteDraft {
  route_code?: string;
  mailbox_code: string;
  bank_code: string;
  enabled: boolean;
  sender_allowlist: string[];
  subject_keywords: string[];
  attachment_filename_regex: string | null;
}

/** "a@x.com, b@y.com" → ["a@x.com", "b@y.com"] */
export function splitList(v: string): string[] {
  return v
    .split(/[,\n]/)
    .map((s) => s.trim())
    .filter(Boolean);
}

export function useSaveRoute(profileCode: string) {
  const invalidate = useInvalidateMail(profileCode);
  return useMutation({
    mutationFn: async (r: RouteDraft) => {
      const row = {
        mailbox_code: r.mailbox_code,
        enabled: r.enabled,
        sender_allowlist: r.sender_allowlist,
        subject_keywords: r.subject_keywords,
        attachment_filename_regex: r.attachment_filename_regex?.trim() || null,
      };
      if (r.route_code) return must(await supabase.from("email_routes").update(row).eq("route_code", r.route_code));
      return must(await supabase.from("email_routes").insert({ ...row, bank_code: r.bank_code, profile_code: profileCode }));
    },
    onSettled: invalidate,
  });
}

export function useDeleteRoute(profileCode: string) {
  const invalidate = useInvalidateMail(profileCode);
  return useMutation({
    mutationFn: async (routeCode: string) => must(await supabase.from("email_routes").delete().eq("route_code", routeCode)),
    onSettled: invalidate,
  });
}

export function useSetMailboxSecret() {
  return useMutation({
    ...SECRET_MUTATION,
    mutationFn: async (v: { mailboxCode: string; value: string }) =>
      must(await supabase.rpc("set_mailbox_secret", { p_mailbox_code: v.mailboxCode, p_key: "refresh_token", p_value: v.value })),
  });
}

// ── source health ──────────────────────────────────────────────────────────
export function useSmsHealth(profileCode: string) {
  return useQuery({
    queryKey: keys.sourceHealth(profileCode),
    queryFn: async () => {
      const [last, unparsed, total, parsed] = await Promise.all([
        supabase.from("sms_messages").select("received_at, sender").eq("profile_code", profileCode).order("received_at", { ascending: false }).limit(1).maybeSingle(),
        supabase.from("sms_messages").select("sms_code", { count: "exact", head: true }).eq("profile_code", profileCode).eq("parse_status", "unparsed"),
        supabase.from("sms_messages").select("sms_code", { count: "exact", head: true }).eq("profile_code", profileCode),
        supabase.from("sms_messages").select("sms_code", { count: "exact", head: true }).eq("profile_code", profileCode).eq("parse_status", "parsed"),
      ]);
      const lastRow = must(last);
      for (const r of [unparsed, total, parsed]) if (r.error) must(r);
      return {
        lastReceivedAt: lastRow?.received_at ?? null,
        lastSender: lastRow?.sender ?? null,
        unparsed: unparsed.count ?? 0,
        total: total.count ?? 0,
        parsed: parsed.count ?? 0,
      };
    },
  });
}

// ── pure helpers for the Settings screen ───────────────────────────────────

export const SETTINGS_TABS = ["sources", "members", "sms", "account", "appearance", "ledger"] as const;
export type SettingsTab = (typeof SETTINGS_TABS)[number];

export function settingsTab(v: string | undefined): SettingsTab {
  return (SETTINGS_TABS as readonly string[]).includes(v ?? "") ? (v as SettingsTab) : "sources";
}

/** A short, stable handle for a user id we can't resolve to an email. */
export function shortUserId(id: string): string {
  return id.replace(/-/g, "").slice(0, 8);
}

/** Stable React key for a member row (invites have no user id). */
export function memberKey(m: Pick<ProfileMember, "user_id" | "email">): string {
  return m.user_id ?? `invite:${(m.email ?? "").toLowerCase()}`;
}

/** What to call a member: their email, else a short id. */
export function memberName(m: Pick<ProfileMember, "user_id" | "email">): string {
  return m.email || (m.user_id ? `Member ${shortUserId(m.user_id)}` : "Unknown");
}

/** Two-letter avatar text from an email ("sara.k@x.com" → "SK"). */
export function memberInitials(m: Pick<ProfileMember, "user_id" | "email">): string {
  const local = (m.email ?? "").split("@")[0] ?? "";
  const parts = local.split(/[._+-]+/).filter(Boolean);
  const letters = parts.length >= 2 ? parts[0]![0]! + parts[1]![0]! : local.slice(0, 2);
  return (letters || (m.user_id ? shortUserId(m.user_id).slice(0, 2) : "?")).toUpperCase();
}

/**
 * Whether the remove action is offered for a row. Owners never see it for
 * themselves or for the last owner (the server refuses that too).
 */
export function canRemoveMember(m: ProfileMember, list: ProfileMember[], myUserId: string | null): boolean {
  if (m.pending || !m.user_id || m.user_id === myUserId) return false;
  if (m.role !== "owner") return true;
  return list.filter((x) => !x.pending && x.role === "owner").length > 1;
}

/** Friendly sentence for remove_profile_member / cancel_profile_invite failures. */
export function memberActionError(e: unknown): string {
  const err = e as { code?: string; message?: string } | null;
  if (err?.code === "22023") return "A ledger needs at least one owner. Make someone else an owner first.";
  if (err?.code === "42501") return "Only owners can change who has access.";
  if (err?.code === "P0002") return "They no longer have access. The list has been refreshed.";
  return err?.message || "Couldn't update access. Try again.";
}

export interface Notice {
  title: string;
  description: string;
  tone: "positive" | "neutral" | "danger";
}

/** Why an invite email could not go out, as a sentence (codes from member-invite). */
function inviteEmailReason(code: string | undefined): string {
  switch (code) {
    case "INVITE_COOLDOWN":
      return "An invite went to this address less than 10 minutes ago, so we didn't send another yet.";
    case "ALREADY_ACTIVE":
      return "They already have a Bank Ledger account, so there's no invite to send. They get access the next time they sign in.";
    case "EMAIL_RATE_LIMITED":
      return "Too many emails have gone out recently.";
    case "RATE_LIMITED":
      return "You've sent a lot of invites in the last hour.";
    default:
      return "The invite email couldn't be sent.";
  }
}

/** The toast after "Invite": who was added, and whether the email went out. */
export function inviteNotice(r: MemberInviteResult, email: string, ledgerName: string): Notice {
  const who = email.trim();
  if (r.status === "added") {
    return { title: "Member added", description: `${who} can now open ${ledgerName}.`, tone: "positive" };
  }
  if (r.invite_sent) {
    return {
      title: "Invite sent",
      description: `We emailed ${who} an invite to ${ledgerName}. They get access when they accept it.`,
      tone: "positive",
    };
  }
  const later = r.invite_error === "ALREADY_ACTIVE" ? "" : " Use Resend invite on their row later.";
  return {
    title: "Invite saved, email not sent",
    description: `${inviteEmailReason(r.invite_error)}${later}`,
    tone: "neutral",
  };
}

/** The toast after "Resend invite" succeeds. */
export function resendNotice(email: string): Notice {
  return { title: "Invite sent again", description: `We emailed ${email} a new invite link.`, tone: "positive" };
}

function errCode(e: unknown): { code?: string; message?: string } {
  return (e ?? {}) as { code?: string; message?: string };
}

/** Sentences shared by "Invite" and "Resend invite" failures, or null. */
function commonInviteError(code: string | undefined): string | null {
  switch (code) {
    case "UNAUTHORIZED":
      return "Your session expired. Sign in again.";
    case "RATE_LIMITED":
      return "You've sent a lot of invites in the last hour. Try again later.";
    case "EMAIL_RATE_LIMITED":
      return "Too many emails have gone out recently. Try again in a while.";
    case "INVITE_FAILED":
      return "The invite email couldn't be sent. Try again in a few minutes.";
    case "ORIGIN_NOT_ALLOWED":
      return "Invites can only be sent from Bank Ledger's usual web address.";
    case "INVALID_EMAIL":
      return "Enter an email address like them@example.com.";
    default:
      return null;
  }
}

/** Friendly sentence for a failed "Invite" (member-invite, action invite). */
export function inviteMemberError(e: unknown): string {
  const err = errCode(e);
  const common = commonInviteError(err.code);
  if (common) return common;
  switch (err.code) {
    case "FORBIDDEN":
      return "Only owners can add people to this ledger.";
    case "INVALID_ROLE":
      return "Choose Owner or Viewer.";
    case "INVALID_PARAMETER":
      return /last owner/i.test(err.message ?? "")
        ? "A ledger needs at least one owner. Make someone else an owner first."
        : "Choose Owner or Viewer.";
    case "INVITE_COOLDOWN":
      return "An invite went to this address less than 10 minutes ago. Try again in a few minutes.";
    case "ALREADY_ACTIVE":
      return "They already have a Bank Ledger account.";
    default:
      return err.message || "Couldn't add them. Try again.";
  }
}

/** Friendly sentence for a failed "Resend invite" (member-invite, action resend). */
export function resendInviteError(e: unknown): string {
  const err = errCode(e);
  const common = commonInviteError(err.code);
  if (common) return common;
  switch (err.code) {
    case "INVITE_COOLDOWN":
      return "An invite went to them less than 10 minutes ago. Give it a few minutes, then resend.";
    case "ALREADY_ACTIVE":
      return "They already have an active Bank Ledger account, so there's nothing to resend. They get access the next time they sign in.";
    case "NOT_A_MEMBER":
      return "This invite was cancelled, so there's nothing to resend. The list has been refreshed.";
    case "FORBIDDEN":
      return "Only owners can resend invites.";
    default:
      return err.message || "Couldn't resend the invite. Try again.";
  }
}

export function isEmail(v: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim());
}

/** Vault status for one secret key. */
export function secretStatus(list: { key: string; updated_at: string }[], key: string): { set: boolean; updatedAt: string | null } {
  const row = list.find((s) => s.key === key);
  return { set: !!row, updatedAt: row?.updated_at ?? null };
}

/** ["a", "b"] → "a, b" for editing comma lists. */
export function joinList(v: string[] | null | undefined): string {
  return (v ?? []).join(", ");
}

/** Returns an error sentence when the regex is invalid. */
export function regexError(v: string | null | undefined): string | null {
  if (!v?.trim()) return null;
  try {
    new RegExp(v);
    return null;
  } catch {
    return "That pattern isn't a valid regular expression.";
  }
}

/** Gmail/Outlook push watches lapse; flag the ones that need attention. */
export function watchState(expiresAt: string | null, now: Date = new Date()): "none" | "expired" | "soon" | "ok" {
  if (!expiresAt) return "none";
  const t = new Date(expiresAt).getTime();
  if (Number.isNaN(t)) return "none";
  const left = t - now.getTime();
  if (left <= 0) return "expired";
  if (left < 24 * 3600_000) return "soon";
  return "ok";
}

export const EMAIL_EVENT_TONE: Record<string, "positive" | "neutral" | "danger" | "warn"> = {
  ingested: "positive",
  duplicate: "neutral",
  ignored: "neutral",
  failed: "danger",
};

/** Bank codes that already have a route (email_routes is unique per profile + bank). */
export function routedBanks(routes: { bank_code: string; route_code: string }[], exceptRoute?: string): Set<string> {
  return new Set(routes.filter((r) => r.route_code !== exceptRoute).map((r) => r.bank_code));
}

export function tokenScopeLabel(scope: string): string {
  return TOKEN_SCOPES.find((s) => s.value === scope)?.label ?? scope;
}
