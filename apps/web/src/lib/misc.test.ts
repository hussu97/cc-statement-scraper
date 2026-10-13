import { describe, expect, it } from "vitest";
import { labelLanes, placeMarks } from "./pace";
import { reconChecks } from "./recon";
import { insightsRange, parseInsightsSearch, parseRangeSearch, parseTabSearch, withInsightsRange, withRange, withTrends } from "./search";

describe("pace rule geometry", () => {
  it("places marks on a shared scale with headroom", () => {
    const { scaleMax, marks } = placeMarks([
      { key: "a", value: "100" },
      { key: "b", value: "50" },
      { key: "c", value: null },
    ]);
    expect(scaleMax).toBeCloseTo(108);
    expect(marks[0]!.at).toBeCloseTo(100 / 108);
    expect(marks[1]!.at).toBeCloseTo(50 / 108);
    expect(marks[2]!.at).toBeNull();
    expect(placeMarks([{ key: "z", value: "0" }]).marks[0]!.at).toBeNull();
  });

  it("puts overlapping labels on separate lanes", () => {
    expect(labelLanes([0.5, 0.55, 0.9])).toEqual([0, 1, 0]);
    expect(labelLanes([null, 0.2])).toEqual([0, 0]);
  });
});

describe("recon checks", () => {
  it("turns checks into rows", () => {
    const rows = reconChecks({ line_count: 30, sum_debits: "100.00", sum_credits: "0.00", held_lines: 0, sms_coverage: 0.5, debits_match: false, balance_equation: true, expected_closing: "500.00", unmatched_sms: 2 });
    expect(rows.map((r) => [r.key, r.ok])).toEqual([
      ["debits", false],
      ["balance", true],
      ["held", true],
      ["sms", false],
      ["coverage", null],
      ["lines", null],
    ]);
    expect(rows.find((r) => r.key === "sms")!.label).toBe("2 SMS purchases missing from this statement");
    expect(reconChecks(null)).toEqual([]);
  });
});

describe("search codecs", () => {
  it("parses tabs and insight ranges", () => {
    expect(parseTabSearch({ tab: "rules" })).toEqual({ tab: "rules" });
    expect(parseTabSearch({ tab: "<script>" })).toEqual({});
    expect(parseInsightsSearch({ range: "ytd", tab: "fx" })).toEqual({ range: "ytd", tab: "fx" });
    expect(parseInsightsSearch({ range: "ytd", from: "2026-01-01", to: "2026-02-01" })).toEqual({ from: "2026-01-01", to: "2026-02-01" });
    expect(insightsRange({}, "2026-10-08")).toEqual({ from: "2026-05-01", to: "2026-10-31", preset: "last_6_months" });
  });

  it("parses Trends grouping and bucket size, dropping defaults and junk", () => {
    expect(parseInsightsSearch({ group: "merchant", grain: "week" })).toEqual({ group: "merchant", grain: "week" });
    expect(parseInsightsSearch({ group: "category", grain: "day" })).toEqual({ grain: "day" });
    expect(parseInsightsSearch({ group: "planet", grain: "year" })).toEqual({});
  });

  it("changes the range without losing the tab or Trends options", () => {
    const s = { tab: "trends", range: "ytd" as const, group: "card" as const, grain: "month" as const };
    expect(withInsightsRange(s, { from: "2026-01-01", to: "2026-03-31" })).toEqual({
      tab: "trends",
      from: "2026-01-01",
      to: "2026-03-31",
      group: "card",
      grain: "month",
    });
    expect(withInsightsRange({ tab: "fx", from: "2026-01-01", to: "2026-03-31" }, { range: "last_6_months" })).toEqual({
      tab: "fx",
      range: "last_6_months",
    });
  });

  it("parses a range-only search (the category view), custom dates winning over a preset", () => {
    expect(parseRangeSearch({ range: "ytd", tab: "fx", q: "x" })).toEqual({ range: "ytd" });
    expect(parseRangeSearch({ range: "ytd", from: "2026-01-01", to: "2026-02-01" })).toEqual({ from: "2026-01-01", to: "2026-02-01" });
    expect(parseRangeSearch({ from: "2026-03-01", to: "2026-02-01" })).toEqual({});
    expect(parseRangeSearch({ range: "forever" })).toEqual({});
    expect(withRange({ range: "last_12_months" })).toEqual({ range: "last_12_months" });
    expect(insightsRange(parseRangeSearch({ from: "2026-10-01", to: "2026-10-31" }), "2026-10-08")).toEqual({
      from: "2026-10-01",
      to: "2026-10-31",
      preset: "this_month",
    });
  });

  it("updates Trends options in the URL", () => {
    expect(withTrends({ range: "ytd" }, { group: "merchant" })).toEqual({ range: "ytd", group: "merchant" });
    expect(withTrends({ group: "merchant", grain: "week" }, { group: "category" })).toEqual({ grain: "week" });
    expect(withTrends({ group: "merchant" }, { grain: "day" })).toEqual({ group: "merchant", grain: "day" });
  });
});
