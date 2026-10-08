import { describe, expect, it } from "vitest";
import {
  allZero,
  anomalyReasonLabel,
  bucketLabel,
  cadenceLabel,
  countLabel,
  defaultGrain,
  deltaTone,
  priceChangeBadge,
  rangeLabel,
  resolveTab,
  yearOptions,
} from "./labels";

describe("insights labels", () => {
  it("resolves unknown tabs to trends", () => {
    expect(resolveTab(undefined)).toBe("trends");
    expect(resolveTab("nope")).toBe("trends");
    expect(resolveTab("fx")).toBe("fx");
  });

  it("tones deltas from the spender's side", () => {
    expect(deltaTone("120.00", "100.00")).toBe("warn");
    expect(deltaTone(80, 100)).toBe("positive");
    expect(deltaTone(100, 100)).toBe("neutral");
    expect(deltaTone(100, 0)).toBe("neutral");
    expect(deltaTone(null, 100)).toBe("neutral");
  });

  it("labels anomaly reasons and cadences", () => {
    expect(anomalyReasonLabel("merchant_outlier")).toBe("Unusual for this merchant");
    expect(anomalyReasonLabel("new_merchant_large")).toBe("Large first purchase");
    expect(anomalyReasonLabel("category_outlier")).toBe("Unusual for this category");
    expect(anomalyReasonLabel(null)).toBe("Unusual");
    expect(cadenceLabel("monthly")).toBe("Monthly");
    expect(cadenceLabel("odd")).toBe("—");
  });

  it("badges price changes above half a percent", () => {
    expect(priceChangeBadge(0.12)).toEqual({ label: "+12%", tone: "warn" });
    expect(priceChangeBadge("-0.05")).toEqual({ label: "−5%", tone: "positive" });
    expect(priceChangeBadge(0.001)).toBeNull();
    expect(priceChangeBadge(null)).toBeNull();
  });

  it("formats buckets per grain", () => {
    expect(bucketLabel("2026-10-01", "month")).toBe("Oct");
    expect(bucketLabel("2026-09-01", "month")).toBe("Sep");
    expect(bucketLabel("2026-10-01", "month", true)).toBe("October 2026");
    expect(bucketLabel("2026-10-05", "week", true)).toBe("Week of 5 Oct");
    expect(bucketLabel("2026-10-05", "day")).toBe("5 Oct");
  });

  it("picks a grain from the range length", () => {
    expect(defaultGrain("2026-10-01", "2026-10-31")).toBe("day");
    expect(defaultGrain("2026-08-01", "2026-10-31")).toBe("week");
    expect(defaultGrain("2026-05-01", "2026-10-31")).toBe("month");
  });

  it("lists years newest first", () => {
    expect(yearOptions(2026, 3)).toEqual([2026, 2025, 2024]);
  });

  it("proves emptiness only when every value is zero", () => {
    expect(allZero([0, "0.00", null])).toBe(true);
    expect(allZero([0, "0.01"])).toBe(false);
  });

  it("pluralises counts", () => {
    expect(countLabel(1, "transaction")).toBe("1 transaction");
    expect(countLabel(1200, "transaction")).toBe("1,200 transactions");
    expect(countLabel(null, "day")).toBe("0 days");
  });

  it("describes a range", () => {
    expect(rangeLabel("2026-05-01", "2026-10-31")).toBe("1 May – 31 Oct 2026");
    expect(rangeLabel("2025-11-01", "2026-10-31")).toBe("1 Nov 2025 – 31 Oct 2026");
  });
});
