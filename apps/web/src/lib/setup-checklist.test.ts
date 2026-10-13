import { describe, expect, it } from "vitest";
import { isEmptyLedger, setupChecklist, setupTarget, spokenStatus, type SetupInputs, type SetupKind } from "./setup-checklist";

const blank: SetupInputs = { lastSmsAt: null, uploads: 0, mailboxes: [], secrets: [], members: [{ pending: false }] };
const step = (i: SetupInputs, kind: SetupKind) => setupChecklist(i).steps.find((s) => s.kind === kind)!;

describe("isEmptyLedger (WEB-27)", () => {
  it("is empty only with no transaction and no card", () => {
    expect(isEmptyLedger({ recent: [], accounts: [] })).toBe(true);
    expect(isEmptyLedger({ recent: [{}], accounts: [] })).toBe(false);
    expect(isEmptyLedger({ recent: [], accounts: [{}] })).toBe(false);
  });
});

describe("setupChecklist (WEB-27)", () => {
  it("lists the five steps in order, all to do on a fresh ledger", () => {
    const c = setupChecklist(blank);
    expect(c.steps.map((s) => s.kind)).toEqual(["statement", "mailbox", "passwords", "sms", "member"]);
    expect(c.steps.every((s) => s.status === "todo")).toBe(true);
    expect(c.progress).toBe("0 of 5 done");
  });

  it("ticks each step only from its data", () => {
    const c = setupChecklist({
      lastSmsAt: "2026-10-08T05:12:44+00:00",
      uploads: 2,
      mailboxes: [{ enabled: true }],
      secrets: [{ key: "FAB_PDF_PASSWORD" }, { key: "ENBD_PDF_PASSWORD" }],
      members: [{ pending: false }, { pending: false }],
    });
    expect(c.steps.every((s) => s.status === "done")).toBe(true);
    expect(c.progress).toBe("5 of 5 done");
    expect(step({ ...blank, secrets: [{ key: "FAB_PDF_PASSWORD" }, { key: "ENBD_PDF_PASSWORD" }] }, "passwords").detail).toBe("Saved for 2 banks.");
    expect(step({ ...blank, secrets: [{ key: "FAB_PDF_PASSWORD" }] }, "passwords").detail).toBe("Saved for 1 bank.");
  });

  it("marks a step whose read failed as unknown, never done or to do", () => {
    const c = setupChecklist({ ...blank, uploads: null, mailboxes: null, secrets: null, members: null });
    expect(c.steps.filter((s) => s.status === "unknown").map((s) => s.kind)).toEqual(["statement", "mailbox", "passwords", "member"]);
    expect(c.progress).toBe("0 of 5 done");
  });

  it("knows SMS from the overview alone", () => {
    expect(step({ ...blank, lastSmsAt: null }, "sms").status).toBe("todo");
    expect(step({ ...blank, lastSmsAt: "2026-10-08T05:12:44+00:00" }, "sms").status).toBe("done");
  });

  it("doesn't count ADCB's customer ID as a statement password", () => {
    expect(step({ ...blank, secrets: [{ key: "ADCB_CID" }] }, "passwords").status).toBe("todo");
  });

  it("doesn't count a paused mailbox as connected, and says it is paused", () => {
    const s = step({ ...blank, mailboxes: [{ enabled: false }] }, "mailbox");
    expect(s.status).toBe("todo");
    expect(s.detail).toMatch(/paused/);
  });

  it("counts a pending invite only as 'Invite sent'", () => {
    const pending = step({ ...blank, members: [{ pending: false }, { pending: true }] }, "member");
    expect(pending).toMatchObject({ status: "done", title: "Invite sent" });
    expect(pending.detail).toMatch(/when they accept/);
    const joined = step({ ...blank, members: [{ pending: false }, { pending: false }, { pending: true }] }, "member");
    expect(joined).toMatchObject({ status: "done", title: "Invite a member", detail: "Someone else has access to this ledger." });
  });

  it("leaves the member step to do when the viewer is the only member", () => {
    expect(step(blank, "member")).toMatchObject({ status: "todo", title: "Invite a member" });
  });
});

describe("setupTarget", () => {
  it("links each step to where it is done", () => {
    expect(setupTarget("statement")).toMatchObject({ to: "/cards", search: { tab: "upload" } });
    expect(setupTarget("mailbox")).toMatchObject({ to: "/settings", search: { tab: "sources" } });
    expect(setupTarget("passwords")).toMatchObject({ to: "/settings", search: { tab: "sources" }, hash: "statement-passwords" });
    expect(setupTarget("sms")).toMatchObject({ to: "/settings", search: { tab: "sms" } });
    expect(setupTarget("member")).toMatchObject({ to: "/settings", search: { tab: "members" } });
  });

  it("speaks each status", () => {
    expect(["done", "todo", "unknown"].map((s) => spokenStatus(s as "done"))).toEqual(["Done", "To do", "Couldn't check"]);
  });
});
