import { describe, expect, it } from "vitest";
import { balanceAnchorNote, formatOutstanding, outstandingCaveat } from "./balances";

describe("formatOutstanding", () => {
  it("shows what is owed", () => {
    expect(formatOutstanding("515.26")).toBe("AED 515.26");
  });
  it("names a credit balance instead of a minus sign", () => {
    expect(formatOutstanding("-12.84")).toBe("AED 12.84 in credit");
    expect(formatOutstanding("-0.40")).toBe("AED 0.40 in credit");
  });
  it("marks estimates", () => {
    expect(formatOutstanding("2969.79", true)).toBe("≈ AED 2,969.79");
  });
  it("never invents a figure", () => {
    expect(formatOutstanding(null)).toBe("—");
  });
});

describe("balanceAnchorNote", () => {
  it("names the statement", () => {
    expect(balanceAnchorNote("statement", "2026-10-01")).toBe("Statement of 1 Oct + activity since");
  });
  it("names a card replacement", () => {
    expect(balanceAnchorNote("balance_migration", "2026-09-15")).toBe("Card replaced 15 Sep + activity since");
  });
  it("says when there is no anchor", () => {
    expect(balanceAnchorNote("none", null)).toBe("No balance from the bank yet");
    expect(balanceAnchorNote(undefined, null)).toBe("No balance from the bank yet");
  });
});

describe("outstandingCaveat", () => {
  it("is silent when complete", () => {
    expect(outstandingCaveat(true)).toBeNull();
  });
  it("counts unpriced charges", () => {
    expect(outstandingCaveat(false, 1)).toBe("Excludes 1 charge without an AED amount");
    expect(outstandingCaveat(false, 3)).toBe("Excludes 3 charges without an AED amount");
  });
  it("falls back to missing anchors", () => {
    expect(outstandingCaveat(false, 0)).toBe("Some cards have no balance from the bank yet");
  });
});
