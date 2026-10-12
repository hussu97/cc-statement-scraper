import { describe, expect, it } from "vitest";
import {
  canRemoveMember,
  inviteMemberError,
  inviteNotice,
  isEmail,
  joinList,
  memberActionError,
  memberInitials,
  memberKey,
  memberName,
  regexError,
  resendInviteError,
  resendNotice,
  routedBanks,
  secretStatus,
  settingsTab,
  shortUserId,
  splitList,
  tokenScopeLabel,
  watchState,
  type ProfileMember,
} from "./settings";

describe("settingsTab", () => {
  it("accepts known tabs and falls back to sources", () => {
    expect(settingsTab("sms")).toBe("sms");
    expect(settingsTab("billing")).toBe("sources");
    expect(settingsTab(undefined)).toBe("sources");
  });
});

describe("members", () => {
  it("shortens user ids", () => {
    expect(shortUserId("1b2c3d4e-0000-4000-8000-000000000000")).toBe("1b2c3d4e");
  });

  describe("invites (member-invite)", () => {
    it("says whether an existing user was added or an invite was emailed", () => {
      expect(inviteNotice({ status: "added", invite_sent: false }, " sara@x.com ", "Home")).toEqual({
        title: "Member added",
        description: "sara@x.com can now open Home.",
        tone: "positive",
      });
      const sent = inviteNotice({ status: "invited", invite_sent: true }, "sara@x.com", "Home");
      expect(sent.title).toBe("Invite sent");
      expect(sent.description).toMatch(/emailed sara@x\.com an invite to Home/);
      expect(sent.tone).toBe("positive");
    });

    it("explains a saved invite whose email did not go out, and points at Resend", () => {
      const notice = (invite_error?: string) => inviteNotice({ status: "invited", invite_sent: false, invite_error }, "sara@x.com", "Home");
      for (const n of [notice("INVITE_COOLDOWN"), notice("EMAIL_RATE_LIMITED"), notice("INVITE_FAILED"), notice(undefined)]) {
        expect(n.title).toBe("Invite saved, email not sent");
        expect(n.tone).toBe("neutral");
        expect(n.description).toMatch(/Resend invite/);
      }
      expect(notice("INVITE_COOLDOWN").description).toMatch(/less than 10 minutes ago/);
      expect(notice("EMAIL_RATE_LIMITED").description).toMatch(/Too many emails/);
      expect(notice("INVITE_FAILED").description).toMatch(/couldn't be sent/);
      expect(notice("ALREADY_ACTIVE").description).toMatch(/already have a Bank Ledger account/);
      expect(notice("ALREADY_ACTIVE").description).not.toMatch(/Resend/);
    });

    it("maps invite failures to sentences", () => {
      expect(inviteMemberError({ code: "FORBIDDEN", message: "x" })).toMatch(/Only owners can add/);
      expect(inviteMemberError({ code: "RATE_LIMITED", message: "too many invites" })).toMatch(/last hour/);
      expect(inviteMemberError({ code: "EMAIL_RATE_LIMITED" })).toMatch(/Too many emails/);
      expect(inviteMemberError({ code: "INVALID_EMAIL" })).toMatch(/them@example\.com/);
      expect(inviteMemberError({ code: "INVALID_ROLE" })).toMatch(/Owner or Viewer/);
      expect(inviteMemberError({ code: "INVALID_PARAMETER", message: "cannot demote the last owner of profile prf_x" })).toMatch(/at least one owner/);
      expect(inviteMemberError({ code: "INVALID_PARAMETER", message: "invalid role x" })).toMatch(/Owner or Viewer/);
      expect(inviteMemberError({ code: "UNAUTHORIZED" })).toMatch(/Sign in again/);
      expect(inviteMemberError({ code: "ORIGIN_NOT_ALLOWED" })).toMatch(/usual web address/);
      expect(inviteMemberError({ message: "boom" })).toBe("boom");
      expect(inviteMemberError(null)).toMatch(/Try again/);
    });

    it("maps resend failures, including cooldown and already active", () => {
      expect(resendInviteError({ code: "INVITE_COOLDOWN", message: "x" })).toMatch(/less than 10 minutes ago/);
      expect(resendInviteError({ code: "ALREADY_ACTIVE", message: "x" })).toMatch(/already have an active Bank Ledger account.*nothing to resend/);
      expect(resendInviteError({ code: "NOT_A_MEMBER" })).toMatch(/cancelled/);
      expect(resendInviteError({ code: "FORBIDDEN" })).toMatch(/Only owners can resend/);
      expect(resendInviteError({ code: "INVITE_FAILED" })).toMatch(/couldn't be sent/);
      expect(resendInviteError({ code: "RATE_LIMITED" })).toMatch(/last hour/);
      expect(resendInviteError({ message: "boom" })).toBe("boom");
      expect(resendInviteError(undefined)).toMatch(/Couldn't resend/);
      expect(resendNotice("sara@x.com")).toEqual({ title: "Invite sent again", description: "We emailed sara@x.com a new invite link.", tone: "positive" });
    });
  });

  const member = (p: Partial<ProfileMember>): ProfileMember => ({
    user_id: "1b2c3d4e-0000-4000-8000-000000000000",
    email: "sara.khan@example.com",
    role: "viewer",
    created_at: "2026-10-01T00:00:00Z",
    pending: false,
    ...p,
  });

  it("names and keys members and invites", () => {
    expect(memberName(member({}))).toBe("sara.khan@example.com");
    expect(memberName(member({ email: null }))).toBe("Member 1b2c3d4e");
    expect(memberKey(member({}))).toBe("1b2c3d4e-0000-4000-8000-000000000000");
    expect(memberKey(member({ user_id: null, email: "New@Example.com", pending: true }))).toBe("invite:new@example.com");
    expect(memberInitials(member({}))).toBe("SK");
    expect(memberInitials(member({ email: "bob@example.com" }))).toBe("BO");
    expect(memberInitials(member({ email: null }))).toBe("1B");
  });

  it("offers removal except for invites, yourself and the last owner", () => {
    const me = member({ user_id: "me", role: "owner" });
    const viewer = member({ user_id: "v" });
    const invite = member({ user_id: null, email: "x@y.co", pending: true, role: "owner" });
    const other = member({ user_id: "o", role: "owner" });
    expect(canRemoveMember(viewer, [me, viewer, invite], "me")).toBe(true);
    expect(canRemoveMember(invite, [me, viewer, invite], "me")).toBe(false);
    expect(canRemoveMember(me, [me, other], "me")).toBe(false);
    expect(canRemoveMember(other, [me, other], "me")).toBe(true);
    // a pending owner invite doesn't count as a second owner
    expect(canRemoveMember(other, [other, invite, viewer], "me")).toBe(false);
  });

  it("explains member action failures", () => {
    expect(memberActionError({ code: "22023", message: "x" })).toMatch(/at least one owner/);
    expect(memberActionError({ code: "42501", message: "x" })).toMatch(/Only owners/);
    expect(memberActionError({ code: "P0002", message: "x" })).toMatch(/no longer have access/);
    expect(memberActionError({ message: "boom" })).toBe("boom");
    expect(memberActionError(null)).toMatch(/Try again/);
  });

  it("checks email shape", () => {
    expect(isEmail(" a@b.co ")).toBe(true);
    expect(isEmail("a@b")).toBe(false);
  });
});

describe("secrets", () => {
  it("reports set/not set without values", () => {
    const list = [{ key: "FAB_PDF_PASSWORD", updated_at: "2026-10-01T10:00:00Z" }];
    expect(secretStatus(list, "FAB_PDF_PASSWORD")).toEqual({ set: true, updatedAt: "2026-10-01T10:00:00Z" });
    expect(secretStatus(list, "ADCB_CID")).toEqual({ set: false, updatedAt: null });
  });
});

describe("email routes", () => {
  it("round-trips comma lists", () => {
    expect(splitList(joinList(["a@x.com", "b@y.com"]))).toEqual(["a@x.com", "b@y.com"]);
    expect(joinList(null)).toBe("");
  });

  it("validates regexes", () => {
    expect(regexError("")).toBeNull();
    expect(regexError("statement.*\\.pdf$")).toBeNull();
    expect(regexError("(")).toMatch(/valid/);
  });

  it("finds banks that already have a route, except the one being edited", () => {
    const routes = [
      { bank_code: "FAB", route_code: "r1" },
      { bank_code: "ADCB", route_code: "r2" },
    ];
    expect([...routedBanks(routes)]).toEqual(["FAB", "ADCB"]);
    expect([...routedBanks(routes, "r1")]).toEqual(["ADCB"]);
  });

  it("flags push watches", () => {
    const now = new Date("2026-10-08T12:00:00Z");
    expect(watchState(null, now)).toBe("none");
    expect(watchState("2026-10-08T11:00:00Z", now)).toBe("expired");
    expect(watchState("2026-10-08T20:00:00Z", now)).toBe("soon");
    expect(watchState("2026-10-12T00:00:00Z", now)).toBe("ok");
  });
});

describe("sources", () => {
  it("labels token scopes", () => {
    expect(tokenScopeLabel("statements:upload")).toMatch(/Upload/);
    expect(tokenScopeLabel("other")).toBe("other");
  });
});
