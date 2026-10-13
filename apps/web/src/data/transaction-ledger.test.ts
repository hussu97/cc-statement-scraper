import { describe, expect, it } from "vitest";
import { elsewhereLedger } from "./transactions";

describe("elsewhereLedger (a txn= from another ledger, WEB-46)", () => {
  const profiles = [
    { profile_code: "pro_a", name: "Home" },
    { profile_code: "pro_b", name: "Business" },
  ];

  it("offers the owning ledger when the caller can switch to it", () => {
    expect(elsewhereLedger("pro_b", "pro_a", profiles)).toEqual({ profile_code: "pro_b", name: "Business" });
  });

  it("is null when nothing owns it, or it's the active ledger", () => {
    expect(elsewhereLedger(null, "pro_a", profiles)).toBeNull();
    expect(elsewhereLedger(undefined, "pro_a", profiles)).toBeNull();
    expect(elsewhereLedger("pro_a", "pro_a", profiles)).toBeNull();
  });

  it("is null for a ledger missing from the switcher (archived, or no longer a member)", () => {
    expect(elsewhereLedger("pro_z", "pro_a", profiles)).toBeNull();
  });
});
