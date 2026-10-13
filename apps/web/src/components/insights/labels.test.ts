import { describe, expect, it } from "vitest";
import {
  allZero,
  anomalyExplanation,
  anomalyReasonLabel,
  timesLabel,
  type AnomalyExplained,
  bucketLabel,
  cadenceLabel,
  changeTone,
  countLabel,
  defaultGrain,
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

  it("tones server change fractions from the spender's side", () => {
    expect(changeTone("0.2000")).toBe("warn");
    expect(changeTone(-0.2)).toBe("positive");
    expect(changeTone("0.0000")).toBe("neutral");
    expect(changeTone(null)).toBe("neutral");
    expect(changeTone(undefined)).toBe("neutral");
  });

  it("labels anomaly reasons and cadences", () => {
    expect(anomalyReasonLabel("merchant_outlier")).toBe("Higher than usual");
    expect(anomalyReasonLabel("new_merchant_large")).toBe("New merchant");
    expect(anomalyReasonLabel("category_outlier")).toBe("Higher than usual");
    expect(anomalyReasonLabel(null)).toBe("Unusual");
    expect(cadenceLabel("monthly")).toBe("Monthly");
    expect(cadenceLabel("odd")).toBe("—");
  });

  it("explains an anomaly in plain words from the server's figures (WEB-16)", () => {
    const row = (over: Partial<AnomalyExplained>): AnomalyExplained => ({
      reason: "merchant_outlier", baseline_scope: "merchant", baseline_mean: 100, times_usual: 5, category_name: "Dining", ...over,
    });
    expect(anomalyExplanation(row({}))).toBe("About 5× what you usually spend here (AED 100.00)");
    expect(anomalyExplanation(row({ reason: "category_outlier", baseline_scope: "category", baseline_mean: "300.00", times_usual: "10", category_name: "Shopping" })))
      .toBe("About 10× your usual Shopping purchase (AED 300.00)");
    expect(anomalyExplanation(row({ reason: "new_merchant_large", baseline_scope: "category", baseline_mean: 3000, times_usual: 2.3, category_name: "Travel" })))
      .toBe("First purchase here, about 2.3× your usual Travel purchase (AED 3,000.00)");
    expect(anomalyExplanation(row({ reason: "new_merchant_large", baseline_scope: null, baseline_mean: null, times_usual: null })))
      .toBe("First purchase here");
    expect(anomalyExplanation(row({ reason: "category_outlier", baseline_scope: "category", category_name: null, times_usual: 4, baseline_mean: 50 })))
      .toBe("About 4× your usual purchase in this category (AED 50.00)");
    expect(anomalyExplanation(row({ times_usual: null }))).toBe("Usually AED 100.00");
    expect(anomalyExplanation(row({ times_usual: null, baseline_mean: null, baseline_scope: null }))).toBe("Higher than usual");
    // No jargon: never a ± or "standard deviation".
    expect(anomalyExplanation(row({}))).not.toMatch(/±|deviation/);
  });

  it("prints the server's rounded multiple as is", () => {
    expect(timesLabel(5)).toBe("5×");
    expect(timesLabel("2.3")).toBe("2.3×");
    expect(timesLabel(null)).toBeNull();
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
