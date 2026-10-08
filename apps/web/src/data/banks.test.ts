import { describe, expect, it } from "vitest";
import { BANK_LOGO_BUCKET, bankFallbackText, bankInfo, bankLogoUrl } from "./banks";

const BASE = "http://127.0.0.1:54321";

describe("bankLogoUrl", () => {
  it("builds the public bank-logos object URL", () => {
    expect(BANK_LOGO_BUCKET).toBe("bank-logos");
    expect(bankLogoUrl("FAB.png", BASE)).toBe("http://127.0.0.1:54321/storage/v1/object/public/bank-logos/FAB.png");
    expect(bankLogoUrl("MASHREQ.png", "https://x.supabase.co/")).toBe("https://x.supabase.co/storage/v1/object/public/bank-logos/MASHREQ.png");
  });

  it("returns null without a path or a base URL", () => {
    expect(bankLogoUrl(null, BASE)).toBeNull();
    expect(bankLogoUrl(undefined, BASE)).toBeNull();
    expect(bankLogoUrl("", BASE)).toBeNull();
    expect(bankLogoUrl("FAB.png", undefined)).toBeNull();
  });

  it("refuses anything that is not a plain object name", () => {
    expect(bankLogoUrl("../statements/x.png", BASE)).toBeNull();
    expect(bankLogoUrl("a/b.png", BASE)).toBeNull();
    expect(bankLogoUrl("FAB.png?x=1", BASE)).toBeNull();
    expect(bankLogoUrl("https://elsewhere.example/FAB.png", BASE)).toBeNull();
    expect(bankLogoUrl("FAB.exe", BASE)).toBeNull();
  });
});

describe("bankFallbackText", () => {
  it("is the short code, upper-cased, at most 4 characters", () => {
    expect(bankFallbackText("FAB")).toBe("FAB");
    expect(bankFallbackText("mashreq")).toBe("MASH");
    expect(bankFallbackText(null)).toBe("?");
    expect(bankFallbackText("  ")).toBe("?");
  });
});

describe("bankInfo", () => {
  const banks = [
    { bank_code: "FAB", name: "First Abu Dhabi Bank", logo_path: "FAB.png" },
    { bank_code: "SIB", name: "Sharjah Islamic Bank", logo_path: null },
  ];
  it("names the bank and resolves its logo", () => {
    expect(bankInfo(banks, "FAB", BASE)).toEqual({ name: "First Abu Dhabi Bank", logoUrl: `${BASE}/storage/v1/object/public/bank-logos/FAB.png` });
    expect(bankInfo(banks, "SIB", BASE)).toEqual({ name: "Sharjah Islamic Bank", logoUrl: null });
  });
  it("falls back to the code before banks load, or for an unknown bank", () => {
    expect(bankInfo(undefined, "ENBD", BASE)).toEqual({ name: "ENBD", logoUrl: null });
    expect(bankInfo(banks, "XYZ", BASE)).toEqual({ name: "XYZ", logoUrl: null });
    expect(bankInfo(banks, null, BASE)).toEqual({ name: "Unknown bank", logoUrl: null });
  });
});
