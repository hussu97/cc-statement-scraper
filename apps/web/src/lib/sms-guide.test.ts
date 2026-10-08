import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  AUTOMATION_STEPS,
  BANNERS,
  PREREQUISITES,
  PRIVACY_NOTE,
  SMS_ACTION,
  SMS_KEYWORD,
  TEST_STEPS,
  TROUBLESHOOTING,
  WHY_MANUAL,
  detectPlatform,
  emphasis,
  smsGuideUrl,
  testflightUrl,
  type GuideField,
} from "./sms-guide";

const IOS = fileURLToPath(new URL("../../../ios", import.meta.url));

const UA = {
  iphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
  ipad: "Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
  ipadDesktopMode: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
  chromeIOS: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/129.0 Mobile/15E148 Safari/604.1",
  mac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36",
  android: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Mobile Safari/537.36",
  windows: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36",
};

const allFields = (): GuideField[] => AUTOMATION_STEPS.flatMap((s) => s.fields ?? []);

describe("detectPlatform", () => {
  it("recognises iPhone, iPad and Chrome on iOS", () => {
    expect(detectPlatform(UA.iphone)).toBe("ios");
    expect(detectPlatform(UA.ipad)).toBe("ios");
    expect(detectPlatform(UA.chromeIOS)).toBe("ios");
  });
  it("treats a Mac user agent with a touch screen as iPadOS, and without one as desktop", () => {
    expect(detectPlatform(UA.ipadDesktopMode, 5)).toBe("ios");
    expect(detectPlatform(UA.mac, 0)).toBe("desktop");
    expect(detectPlatform(UA.mac)).toBe("desktop");
  });
  it("separates Android from desktop", () => {
    expect(detectPlatform(UA.android, 5)).toBe("android");
    expect(detectPlatform(UA.windows)).toBe("desktop");
    expect(detectPlatform("")).toBe("desktop");
  });
});

describe("testflightUrl", () => {
  it("accepts public TestFlight links only", () => {
    expect(testflightUrl("https://testflight.apple.com/join/AbCdEf12")).toBe("https://testflight.apple.com/join/AbCdEf12");
    expect(testflightUrl("  https://testflight.apple.com/join/x  ")).toBe("https://testflight.apple.com/join/x");
  });
  it("hides the button when unset or not TestFlight", () => {
    expect(testflightUrl(undefined)).toBeNull();
    expect(testflightUrl("")).toBeNull();
    expect(testflightUrl("http://testflight.apple.com/join/x")).toBeNull();
    expect(testflightUrl("https://evil.example/testflight.apple.com")).toBeNull();
    expect(testflightUrl("not a url")).toBeNull();
  });
});

describe("smsGuideUrl", () => {
  it("points at the SMS tab of Settings", () => {
    expect(smsGuideUrl("https://ledger.example")).toBe("https://ledger.example/settings?tab=sms");
    expect(smsGuideUrl("http://127.0.0.1:5173/")).toBe("http://127.0.0.1:5173/settings?tab=sms");
  });
});

describe("emphasis", () => {
  it("marks *on-screen names* and keeps the rest", () => {
    expect(emphasis("Tap *Next*.")).toEqual([
      { text: "Tap ", strong: false },
      { text: "Next", strong: true },
      { text: ".", strong: false },
    ]);
    expect(emphasis("plain")).toEqual([{ text: "plain", strong: false }]);
    expect(emphasis("a * b")).toEqual([{ text: "a * b", strong: false }]);
  });
  it("leaves no unbalanced asterisks in the guide copy", () => {
    const texts = [...PREREQUISITES.map((p) => p.detail), ...AUTOMATION_STEPS.map((s) => s.detail), ...TEST_STEPS.map((t) => t.detail)];
    for (const t of texts) expect(emphasis(t).some((r) => r.text.includes("*")), t).toBe(false);
  });
});

describe("automation steps", () => {
  it("have unique ids and titles", () => {
    const ids = AUTOMATION_STEPS.map((s) => s.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(new Set(AUTOMATION_STEPS.map((s) => s.title)).size).toBe(ids.length);
    for (const list of [PREREQUISITES, TEST_STEPS]) expect(new Set(list.map((x) => x.id)).size).toBe(list.length);
  });

  it("walk the iOS flow in order", () => {
    const order = ["open-automation", "new-automation", "keyword", "sender", "run-immediately", "blank", "add-action", "message", "sender-variable", "done"];
    expect(AUTOMATION_STEPS.map((s) => s.id)).toEqual(order);
    expect(AUTOMATION_STEPS[0]?.opensShortcuts).toBe(true);
  });

  it("set Message Contains to the keyword, with a copy button", () => {
    const f = allFields().find((x) => x.label === "Message Contains");
    expect(f?.value).toEqual({ kind: "text", text: SMS_KEYWORD });
    expect(f?.copy).toBe(SMS_KEYWORD);
  });

  it("run immediately with Notify When Run on", () => {
    expect(allFields().find((x) => x.label === "Run Immediately")?.value).toEqual({ kind: "selected" });
    expect(allFields().find((x) => x.label === "Notify When Run")?.value).toEqual({ kind: "toggle", on: true });
  });

  it("add the action by name, with a copy button", () => {
    const step = AUTOMATION_STEPS.find((s) => s.id === "add-action");
    expect(step?.title).toContain(SMS_ACTION);
    expect(step?.fields?.[0]?.copy).toBe(SMS_ACTION);
  });

  it("map Message → Shortcut Input › Content and Sender → Shortcut Input › Sender", () => {
    const vars = allFields().filter((f) => f.value.kind === "variable");
    expect(vars.map((f) => [f.label, f.value])).toEqual([
      ["Message", { kind: "variable", variable: "Shortcut Input", property: "Content" }],
      ["Sender", { kind: "variable", variable: "Shortcut Input", property: "Sender" }],
    ]);
  });
});

describe("guide copy", () => {
  const copy = [
    WHY_MANUAL,
    PRIVACY_NOTE,
    ...PREREQUISITES.flatMap((p) => [p.title, p.detail]),
    ...AUTOMATION_STEPS.flatMap((s) => [s.title, s.detail]),
    ...TEST_STEPS.map((t) => t.detail),
    ...BANNERS.flatMap((b) => [b.says, b.means]),
    ...TROUBLESHOOTING.flatMap((t) => [t.problem, t.fix]),
  ];
  it("names the product Bank Ledger, never bare Ledger", () => {
    for (const t of copy) expect(t, t).not.toMatch(/(?<!Bank )\bLedger\b/);
  });
  it("explains why setup is manual and that OTPs never leave the phone", () => {
    expect(WHY_MANUAL).toMatch(/doesn't let apps create automations/);
    expect(PRIVACY_NOTE).toMatch(/one-time passcodes/i);
    expect(PRIVACY_NOTE).toMatch(/never leave/);
  });
});

// The guide must describe what the iOS app actually ships.
describe("matches the iOS app", () => {
  it("uses LedgerKit's keyword and the intent's title", () => {
    const guide = readFileSync(`${IOS}/LedgerKit/Sources/LedgerKit/Screens/SettingsModel.swift`, "utf8");
    expect(guide).toContain(`public static let keywords = ["${SMS_KEYWORD}"]`);
    const intent = readFileSync(`${IOS}/Ledger/Intents/LogBankSMSIntent.swift`, "utf8");
    expect(intent).toContain(`static let title: LocalizedStringResource = "${SMS_ACTION}"`);
    expect(intent).toMatch(/@Parameter\(title: "Message"/);
    expect(intent).toMatch(/@Parameter\(title: "Sender"/);
  });
});
