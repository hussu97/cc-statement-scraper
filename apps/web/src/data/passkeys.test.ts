import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { defaultPasskeyName, passkeyOfferDeclined, passkeysSupported, setPasskeyOfferDeclined, shouldOfferPasskey } from "./passkeys";
import { cleanCode, isPasskeyCancel, passkeyErrorMessage, signInErrorMessage } from "./auth";

describe("passkey offer after an email-code sign-in", () => {
  it("offers only when supported, not declined and the account has no passkeys", () => {
    expect(shouldOfferPasskey({ supported: true, declined: false, passkeyCount: 0 })).toBe(true);
    expect(shouldOfferPasskey({ supported: false, declined: false, passkeyCount: 0 })).toBe(false);
    expect(shouldOfferPasskey({ supported: true, declined: true, passkeyCount: 0 })).toBe(false);
    expect(shouldOfferPasskey({ supported: true, declined: false, passkeyCount: 1 })).toBe(false);
    // Couldn't list passkeys: don't nag.
    expect(shouldOfferPasskey({ supported: true, declined: false, passkeyCount: null })).toBe(false);
  });

  describe("'Not now' is remembered per user", () => {
    beforeEach(() => {
      const m = new Map<string, string>();
      vi.stubGlobal("window", {
        localStorage: { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k) },
      });
    });
    afterEach(() => vi.unstubAllGlobals());
    it("round-trips and clears", () => {
      expect(passkeyOfferDeclined("u1")).toBe(false);
      setPasskeyOfferDeclined("u1", true);
      expect(passkeyOfferDeclined("u1")).toBe(true);
      expect(passkeyOfferDeclined("u2")).toBe(false);
      setPasskeyOfferDeclined("u1", false);
      expect(passkeyOfferDeclined("u1")).toBe(false);
    });
  });

  it("detects WebAuthn support", () => {
    expect(passkeysSupported({})).toBe(false);
    expect(passkeysSupported({ PublicKeyCredential: function PublicKeyCredential() {} })).toBe(true);
  });
});

describe("defaultPasskeyName", () => {
  it.each([
    ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", "Safari on Mac"],
    ["Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", "Safari on iPhone"],
    ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 Edg/130.0", "Edge on Windows"],
    ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36", "Chrome on Windows"],
    ["Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0", "Firefox on Linux"],
    ["", "Browser on this device"],
  ])("%s → %s", (ua, name) => expect(defaultPasskeyName(ua)).toBe(name));
});

describe("passkey errors", () => {
  it("treats browser cancellation as no-op, not an error", () => {
    expect(isPasskeyCancel({ code: "ERROR_CEREMONY_ABORTED", message: "x" })).toBe(true);
    expect(isPasskeyCancel({ name: "NotAllowedError", message: "The operation either timed out or was not allowed." })).toBe(true);
    expect(isPasskeyCancel({ message: "y", cause: { name: "AbortError" } })).toBe(true);
    expect(isPasskeyCancel({ code: "webauthn_verification_failed", message: "Verification failed" })).toBe(false);
    expect(isPasskeyCancel(null)).toBe(false);
  });

  it("maps GoTrue codes to sentences", () => {
    expect(passkeyErrorMessage("webauthn_credential_not_found")).toMatch(/no longer on your Bank Ledger account/);
    expect(passkeyErrorMessage("webauthn_credential_exists")).toMatch(/already has a passkey/);
    expect(passkeyErrorMessage("something_else")).toBeNull();
    expect(signInErrorMessage({ message: "raw", code: "webauthn_challenge_expired" })).toBe("The passkey prompt timed out. Try again.");
    expect(signInErrorMessage(new Error("Error sending magic link email"))).toBe("We couldn't send the email just now. Try again in a minute.");
  });
});

describe("cleanCode", () => {
  it("keeps up to 10 digits", () => {
    expect(cleanCode(" 123 456 ")).toBe("123456");
    expect(cleanCode("12345678901234")).toBe("1234567890");
    expect(cleanCode("ab12")).toBe("12");
  });
});
