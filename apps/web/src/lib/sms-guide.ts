/**
 * The iPhone SMS setup guide (Settings → iPhone SMS) as data, so the page
 * stays layout-only and the steps can be checked by tests.
 *
 * It describes the ONE automation the iOS app expects (apps/ios/README.md,
 * "SMS capture"): Message → Message Contains "Card" → Run Immediately with
 * Notify When Run on → "Log Bank SMS" with Message = Shortcut Input → Content
 * and Sender = Shortcut Input → Sender. sms-guide.test.ts pins the keyword and
 * the action name to the Swift sources.
 */
import { BRAND_NAME } from "./brand";

/** The single "Message Contains" keyword (LedgerKit `SMSAutomationGuide.keywords`). */
export const SMS_KEYWORD = "Card";
/**
 * The optional second automation's keyword, for bank-account alerts (LedgerKit
 * `SMSAutomationGuide.accountKeyword`, Phase 2b). ADCB and FAB account alerts never say "Card".
 */
export const SMS_ACCOUNT_KEYWORD = "Account";
/** The App Intent's title (`LogBankSMSIntent.title`). */
export const SMS_ACTION = "Log Bank SMS";
/** Opens the Shortcuts app. Only meaningful on iPhone/iPad. */
export const SHORTCUTS_URL = "shortcuts://";

export type Platform = "ios" | "android" | "desktop";

/**
 * Where the guide is being read. iPadOS Safari reports a Mac user agent, so a
 * "Macintosh" UA with a touch screen counts as iOS.
 */
export function detectPlatform(userAgent: string, maxTouchPoints = 0): Platform {
  if (/\b(iPhone|iPad|iPod)\b/i.test(userAgent)) return "ios";
  if (/\bMacintosh\b/.test(userAgent) && maxTouchPoints > 1) return "ios";
  if (/\bAndroid\b/i.test(userAgent)) return "android";
  return "desktop";
}

/** The public TestFlight link from `VITE_TESTFLIGHT_URL`, or null when unset or not a TestFlight URL. */
export function testflightUrl(raw: string | undefined | null): string | null {
  const value = (raw ?? "").trim();
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname === "testflight.apple.com" ? url.toString() : null;
  } catch {
    return null;
  }
}

/** The address the desktop QR code opens: this guide, on the phone. */
export function smsGuideUrl(origin: string): string {
  return `${origin.replace(/\/+$/, "")}/settings?tab=sms`;
}

// ---------- copy with light emphasis ----------

/** A run of guide text; `strong` runs name something on screen (a tab, a button). */
export interface TextRun {
  text: string;
  strong: boolean;
}

/** Splits `"Tap *Next*."` into runs; `*…*` marks on-screen names. */
export function emphasis(text: string): TextRun[] {
  return text
    .split(/(\*[^*]+\*)/)
    .filter(Boolean)
    .map((part) => (part.startsWith("*") && part.endsWith("*") && part.length > 2 ? { text: part.slice(1, -1), strong: true } : { text: part, strong: false }));
}

// ---------- mock-ups of what the screen should show ----------

export type FieldValue =
  | { kind: "text"; text: string }
  | { kind: "placeholder"; text: string }
  | { kind: "toggle"; on: boolean }
  | { kind: "selected" }
  | { kind: "variable"; variable: "Shortcut Input"; property: "Content" | "Sender" };

/** One row of the iOS screen as it should look after the step. `copy` adds a copy button. */
export interface GuideField {
  label: string;
  value: FieldValue;
  copy?: string;
}

export interface GuideStep {
  id: string;
  title: string;
  detail: string;
  fields?: GuideField[];
  /** Show "Open Shortcuts" next to this step (iPhone only). */
  opensShortcuts?: boolean;
}

export const PREREQUISITES: { id: string; title: string; detail: string; testflight?: boolean }[] = [
  {
    id: "install",
    title: `Install ${BRAND_NAME} on your iPhone`,
    detail: `It's on TestFlight: install Apple's *TestFlight* app, open the invite link, then tap *Install*.`,
    testflight: true,
  },
  { id: "sign-in", title: "Sign in", detail: `Open ${BRAND_NAME} and sign in with the same email you use here.` },
  {
    id: "target",
    title: "Choose where SMS go",
    detail: `In ${BRAND_NAME} → *Settings*, check *SMS go to* shows the ledger card alerts should land in. Only ledgers you own are listed.`,
  },
];

export const AUTOMATION_STEPS: GuideStep[] = [
  {
    id: "open-automation",
    title: "Open Shortcuts → Automation",
    detail: "Open the *Shortcuts* app (it comes with iPhone) and tap *Automation* at the bottom of the screen.",
    opensShortcuts: true,
  },
  {
    id: "new-automation",
    title: "Start a new automation",
    detail: "Tap *+* in the top-right corner (or *New Automation* if you have none yet), scroll down and tap *Message*.",
  },
  {
    id: "keyword",
    title: `Message Contains: ${SMS_KEYWORD}`,
    detail: `Tap *Message Contains*, type ${SMS_KEYWORD} and tap *Done*. Every credit-card alert from ADCB, FAB, Emirates NBD and SIB contains this word.`,
    fields: [{ label: "Message Contains", value: { kind: "text", text: SMS_KEYWORD }, copy: SMS_KEYWORD }],
  },
  {
    id: "sender",
    title: "Leave Sender empty",
    detail: "Banks text from names like ADCBAlert, not from contacts, so leave *Sender* as it is. The automation then catches every bank.",
    fields: [{ label: "Sender", value: { kind: "placeholder", text: "Choose" } }],
  },
  {
    id: "run-immediately",
    title: "Run Immediately, Notify When Run on",
    detail: "Select *Run Immediately* and make sure *Notify When Run* is on, so a banner tells you what happened to each alert. Tap *Next*.",
    fields: [
      { label: "Run Immediately", value: { kind: "selected" } },
      { label: "Notify When Run", value: { kind: "toggle", on: true } },
    ],
  },
  {
    id: "blank",
    title: "New Blank Automation",
    detail: "On the next screen, tap *New Blank Automation*.",
  },
  {
    id: "add-action",
    title: `Add “${SMS_ACTION}”`,
    detail: `Tap *Add Action*, search for ${SMS_ACTION} and tap it. It's listed under ${BRAND_NAME}.`,
    fields: [{ label: "Search", value: { kind: "text", text: SMS_ACTION }, copy: SMS_ACTION }],
  },
  {
    id: "message",
    title: "Pass the message",
    detail:
      "In the action, tap the blue *Message* placeholder and pick *Shortcut Input* in the bar above the keyboard. Then tap *Shortcut Input* in the action and choose *Content*.",
    fields: [{ label: "Message", value: { kind: "variable", variable: "Shortcut Input", property: "Content" } }],
  },
  {
    id: "sender-variable",
    title: "Pass the sender",
    detail: "Tap the *Sender* placeholder, pick *Shortcut Input* again, tap it and choose *Sender*.",
    fields: [{ label: "Sender", value: { kind: "variable", variable: "Shortcut Input", property: "Sender" } }],
  },
  {
    id: "done",
    title: "Tap Done",
    detail: `Tap *Done* in the top-right corner. The Automation tab now lists “When I get a message containing ${SMS_KEYWORD}”.`,
  },
];

/** The optional second automation, shown after the steps above (Phase 2b). */
export const ACCOUNT_AUTOMATION = {
  title: "Optional: bank account alerts",
  detail:
    `To track a bank account's balance and transfers, create a second automation the same way with *Message Contains* set to *${SMS_ACCOUNT_KEYWORD}*, ` +
    `then add that account in ${BRAND_NAME}. An alert that says both words is logged once.`,
};

export const TEST_STEPS: { id: string; detail: string }[] = [
  {
    id: "send-test",
    detail: `In ${BRAND_NAME} → *Settings*, tap *Send test*. It checks your sign-in and the *SMS go to* ledger without sending anything real.`,
  },
  {
    id: "text-me",
    detail: `To check the automation itself, ask someone to text you “${SMS_KEYWORD} test”. A banner should say it was skipped as not a credit-card transaction: that means it works, and the message stayed on your phone.`,
  },
  {
    id: "real",
    detail: "After your next card purchase, the transaction shows up in *Activity* within seconds, and *Last captured* in the app updates.",
  },
];

/** What the banner after each alert means. */
export const BANNERS: { says: string; means: string }[] = [
  { says: "Logged to <your ledger>.", means: "The purchase is recorded." },
  { says: "…doesn't know this card yet", means: "Logged, but add the card: Overview → Needs review." },
  { says: "Skipped: one-time passcode.", means: "Dropped on your phone. Never sent." },
  { says: "Logged to <your ledger> as not a card purchase.", means: "A debit-card, account or other alert: kept, not counted as spend." },
  { says: "…can't read this message format yet", means: "Kept. Bank Ledger learns the format and files it; see Review." },
  { says: "Saved on this iPhone…", means: "You're offline or signed out. It sends by itself later." },
];

export const TROUBLESHOOTING: { problem: string; fix: string }[] = [
  {
    problem: "Nothing happens when an alert arrives",
    fix: "In Shortcuts → Automation, check the automation is listed and set to Run Immediately. If it asks before running, it was saved as Run After Confirmation.",
  },
  {
    problem: "Alerts aren't in Messages",
    fix: "The automation sees what arrives in the Messages app, as SMS or iMessage. Alerts that come only as WhatsApp messages or banking-app notifications can't be captured.",
  },
  {
    problem: "No banner",
    fix: "A Focus or Do Not Disturb can hide the banner; the automation still runs. Check Last captured in the app.",
  },
  {
    problem: "Refunds don't appear",
    fix: `Emirates NBD refunds say “your card ending”. Message Contains should match “card” whatever the case; if refunds still don't appear, add a second automation with the lowercase word card. Keep it to these two: each extra automation runs the action again for the same alert.`,
  },
  {
    problem: "“Log Bank SMS” isn't in the search",
    fix: `Open ${BRAND_NAME} once after installing or updating it, then search again.`,
  },
];

export const PRIVACY_NOTE =
  `One-time passcodes are dropped on your iPhone and never leave it. ` +
  `Every other message the automation hands over is sent over your signed-in session, and Bank Ledger files ` +
  `debit-card, account and other non-purchase alerts as ignored.`;

export const WHY_MANUAL = `iOS doesn't let apps create automations for you, so this is a one-time setup that takes about a minute.`;
