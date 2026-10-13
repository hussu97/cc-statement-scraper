import { describe, expect, it } from "vitest";
import { parseSignInSearch, safeRedirect, signInSearch } from "./redirect";

describe("safeRedirect (WEB-39)", () => {
  it("keeps a same-origin path with its search and hash", () => {
    expect(safeRedirect("/activity?txn=txn_01k6abcdefghjkmnpqrstvwxyz")).toBe("/activity?txn=txn_01k6abcdefghjkmnpqrstvwxyz");
    expect(safeRedirect("/settings?tab=sources#statement-passwords")).toBe("/settings?tab=sources#statement-passwords");
    expect(safeRedirect("/statements/stm_01k6abcdefghjkmnpqrstvwxyz")).toBe("/statements/stm_01k6abcdefghjkmnpqrstvwxyz");
    expect(safeRedirect("/?month=2026-09-01")).toBe("/?month=2026-09-01");
  });

  it.each([
    ["protocol-relative", "//evil.example/x"],
    ["absolute http", "https://evil.example/"],
    ["javascript scheme", "javascript:alert(1)"],
    ["data scheme", "data:text/html,hi"],
    ["relative without slash", "activity"],
    ["backslash", "/\\evil.example"],
    ["backslash later", "/activity\\..\\x"],
    ["leading backslashes", "\\\\evil.example"],
    ["tab that browsers strip", "/\t/evil.example"],
    ["newline", "/\n/evil.example"],
    ["space", "/ /evil.example"],
    ["encoded slash", "/%2F%2Fevil.example"],
    ["encoded backslash", "/%5cevil.example"],
    ["empty", ""],
  ])("rejects %s", (_name, raw) => {
    expect(safeRedirect(raw)).toBeUndefined();
  });

  it("rejects non-strings and very long values", () => {
    expect(safeRedirect(undefined)).toBeUndefined();
    expect(safeRedirect(42)).toBeUndefined();
    expect(safeRedirect(["/activity"])).toBeUndefined();
    expect(safeRedirect(`/${"a".repeat(2048)}`)).toBeUndefined();
  });

  it("drops a redirect back to /signin, or to the plain home page", () => {
    expect(safeRedirect("/signin")).toBeUndefined();
    expect(safeRedirect("/signin?redirect=/activity")).toBeUndefined();
    expect(safeRedirect("/")).toBeUndefined();
  });

  it("normalises dot segments, so the result is still a path on this origin", () => {
    expect(safeRedirect("/activity/../cards")).toBe("/cards");
  });
});

describe("signInSearch / parseSignInSearch", () => {
  it("carries a safe path and omits an unsafe one", () => {
    expect(signInSearch("/activity?txn=x")).toEqual({ redirect: "/activity?txn=x" });
    expect(signInSearch("/")).toEqual({});
    expect(parseSignInSearch({ redirect: "/review" })).toEqual({ redirect: "/review" });
    expect(parseSignInSearch({ redirect: "//evil.example" })).toEqual({});
    expect(parseSignInSearch({ redirect: 1 })).toEqual({});
    expect(parseSignInSearch({})).toEqual({});
  });
});
