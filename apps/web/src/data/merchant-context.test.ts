import { describe, expect, it } from "vitest";
import { merchantContextLine, type MerchantContext } from "./transactions";
import { keys } from "./keys";

const ctx = (c: Partial<MerchantContext>): MerchantContext => ({
  merchant_code: "mer_x",
  visit_count: 13,
  avg_aed: "254.31",
  total_6m_aed: "3306.00",
  first_seen: "2024-03-02",
  ...c,
});

describe("merchantContextLine", () => {
  it("reads the server's figures as one line", () => {
    expect(merchantContextLine(ctx({}))).toBe("13 visits · avg AED 254 · AED 3,306 in 6 months · since 2 Mar 2024");
  });
  it("calls a single purchase the first visit, without an average or a start date", () => {
    expect(merchantContextLine(ctx({ visit_count: 1, avg_aed: "40.00", total_6m_aed: "40.00", first_seen: "2026-10-01" }))).toBe(
      "First visit · AED 40 in 6 months",
    );
  });
  it("leaves out a zero 6-month total (all visits older)", () => {
    expect(merchantContextLine(ctx({ visit_count: 2, avg_aed: "10.00", total_6m_aed: "0.00" }))).toBe("2 visits · avg AED 10 · since 2 Mar 2024");
  });
  it("shows a net-negative 6 months as the server sends it", () => {
    expect(merchantContextLine(ctx({ visit_count: 3, total_6m_aed: "-20.00" }))).toContain("−AED 20 in 6 months");
  });
  it("says nothing without a visit or without data", () => {
    expect(merchantContextLine(ctx({ visit_count: 0, avg_aed: null, total_6m_aed: "0.00", first_seen: null }))).toBeNull();
    expect(merchantContextLine(undefined)).toBeNull();
    expect(merchantContextLine(null)).toBeNull();
  });
});

describe("keys.merchantContext", () => {
  it("lives under the transactions domain, so a category or exclude change refreshes it", () => {
    expect(keys.merchantContext("prf_x", "mer_x")).toEqual(["p", "prf_x", "transactions", "merchant", "mer_x"]);
  });
});
