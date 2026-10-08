import { describe, expect, it } from "vitest";
import { publishableKey } from "./supabase-key";

describe("publishableKey", () => {
  it("accepts a publishable key, trimmed", () => {
    expect(publishableKey(" sb_publishable_abc \n")).toBe("sb_publishable_abc");
  });

  it("still accepts a legacy anon JWT", () => {
    expect(publishableKey("eyJhbGciOiJIUzI1NiJ9.e30.sig")).toBe("eyJhbGciOiJIUzI1NiJ9.e30.sig");
  });

  it("treats empty or missing values as not configured", () => {
    expect(publishableKey(undefined)).toBeNull();
    expect(publishableKey("   ")).toBeNull();
  });

  it("refuses a secret key so it is never shipped to the browser", () => {
    expect(publishableKey("sb_secret_abc")).toBeNull();
  });
});
