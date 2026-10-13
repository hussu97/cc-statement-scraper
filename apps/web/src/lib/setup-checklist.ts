// "Get your ledger going" (BACKLOG WEB-27): what Overview shows for a ledger
// with no transactions and no cards, instead of AED 0.00, an empty pace rule
// and four empty states. Each step is ticked only when server data proves it;
// a step whose data couldn't be read is "unknown", never claimed done or undone
// (CLAUDE.md §4.3). The rules mirror iOS `SetupChecklist` (LedgerKit, IOS-23).

export type SetupKind = "statement" | "mailbox" | "passwords" | "sms" | "member";
export type SetupStatus = "done" | "todo" | "unknown";

export interface SetupStep {
  kind: SetupKind;
  status: SetupStatus;
  title: string;
  detail: string;
}

export interface SetupChecklist {
  steps: SetupStep[];
  /** "2 of 5 done". */
  progress: string;
}

/** What each step is proven by. `null` means the read failed, so the step is unknown. */
export interface SetupInputs {
  /** `overview.last_sms_at`: the newest SMS the ledger received. */
  lastSmsAt: string | null;
  /** Documents uploaded to the ledger (any source), exact head count. */
  uploads: number | null;
  /** `email_mailboxes` rows. */
  mailboxes: readonly { enabled: boolean }[] | null;
  /** `list_profile_secrets`: which Vault keys are set. */
  secrets: readonly { key: string }[] | null;
  /** `list_profile_members`: members (the viewer included) and pending invites. */
  members: readonly { pending: boolean }[] | null;
}

export const SETUP_TITLE = "Get your ledger going";
export const SETUP_INTRO = "No cards or transactions yet. These steps bring your spending in.";
export const SETUP_VIEWER_NOTE = "Only the ledger's owners can do these.";

/** No transaction at all (`recent` is the ledger's latest, not the month's) and no card. */
export function isEmptyLedger(o: { recent: readonly unknown[]; accounts: readonly unknown[] }): boolean {
  return o.recent.length === 0 && o.accounts.length === 0;
}

const known = <T>(v: T | null, done: (v: T) => boolean): SetupStatus => (v === null ? "unknown" : done(v) ? "done" : "todo");

/** A statement PDF password (ADCB's customer ID alone opens nothing). */
const isPdfPassword = (key: string) => key.endsWith("_PDF_PASSWORD");

export function setupChecklist(i: SetupInputs): SetupChecklist {
  const passwords = i.secrets?.filter((s) => isPdfPassword(s.key)).length ?? null;
  const enabledMailboxes = i.mailboxes?.filter((m) => m.enabled).length ?? null;
  const joined = i.members ? i.members.filter((m) => !m.pending).length > 1 : null;
  const invited = i.members ? i.members.some((m) => m.pending) : null;

  const statement = known(i.uploads, (n) => n > 0);
  const mailbox = known(enabledMailboxes, (n) => n > 0);
  const pwd = known(passwords, (n) => n > 0);
  const sms: SetupStatus = i.lastSmsAt ? "done" : "todo";
  // Like iOS, a pending invite ticks the step, but it only says "Invite sent":
  // nobody else has access until they accept it.
  const member = known(i.members, () => !!joined || !!invited);

  const steps: SetupStep[] = [
    {
      kind: "statement",
      status: statement,
      title: "Upload a statement",
      detail:
        statement === "done"
          ? "A statement is in. Its cards show here once it has been read."
          : "Add a bank statement PDF. Its cards and transactions appear once it has been read.",
    },
    {
      kind: "mailbox",
      status: mailbox,
      title: "Connect a mailbox",
      detail:
        mailbox === "done"
          ? "Statement emails from your banks are picked up as they arrive."
          : i.mailboxes && i.mailboxes.length > 0
            ? "Your mailbox is paused. Turn it back on to pick up statement emails."
            : "Bank Ledger can pick statement PDFs up from your bank emails as they arrive.",
    },
    {
      kind: "passwords",
      status: pwd,
      title: "Set statement passwords",
      detail:
        pwd === "done"
          ? `Saved for ${passwords} ${passwords === 1 ? "bank" : "banks"}.`
          : "Banks lock statement PDFs. Save each bank's password so they can be read.",
    },
    {
      kind: "sms",
      status: sms,
      title: "Set up SMS capture",
      detail: sms === "done" ? "Card alerts are reaching this ledger." : "A Shortcuts automation on your phone sends each bank SMS here as it arrives.",
    },
    {
      kind: "member",
      status: member,
      title: member === "done" && !joined ? "Invite sent" : "Invite a member",
      detail:
        member !== "done"
          ? "Share this ledger with someone, as an owner or a viewer."
          : joined
            ? "Someone else has access to this ledger."
            : "They get access when they accept it.",
    },
  ];
  const done = steps.filter((s) => s.status === "done").length;
  return { steps, progress: `${done} of ${steps.length} done` };
}

/** Where a step is done. `search`/`hash` are the target screen's URL parts. */
export type SetupTarget =
  | { to: "/cards"; search: { tab: "upload" }; label: string }
  | { to: "/settings"; search: { tab: "sources" | "sms" | "members" }; hash?: string; label: string };

export function setupTarget(kind: SetupKind): SetupTarget {
  switch (kind) {
    case "statement":
      return { to: "/cards", search: { tab: "upload" }, label: "Upload" };
    case "mailbox":
      return { to: "/settings", search: { tab: "sources" }, label: "Connect" };
    case "passwords":
      return { to: "/settings", search: { tab: "sources" }, hash: "statement-passwords", label: "Set passwords" };
    case "sms":
      return { to: "/settings", search: { tab: "sms" }, label: "Set up" };
    case "member":
      return { to: "/settings", search: { tab: "members" }, label: "Invite" };
  }
}

/** Screen-reader value for a step's status. */
export function spokenStatus(s: SetupStatus): string {
  return s === "done" ? "Done" : s === "todo" ? "To do" : "Couldn't check";
}
