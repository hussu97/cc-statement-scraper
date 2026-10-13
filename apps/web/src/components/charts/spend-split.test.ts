import { describe, expect, it } from "vitest";
import type { SpendBreakdown } from "@/data/analytics";
import { breakdownGroupFor, groupActivitySearch, monthDate, monthShare, splitChart, splitFill, TOTAL_KEY } from "./spend-split";
import { OTHER_FILL } from "./palette";

const byCategory: SpendBreakdown = {
  group_by: "category",
  total: "1500.00",
  months: ["2026-08", "2026-09"],
  groups: [
    { key: "cat_dining", label: "Dining", color_token: "cat-3", logo_path: null, total: "900.00", share: "0.6000" },
    { key: "__uncategorized__", label: "Uncategorised", color_token: null, logo_path: null, total: "400.00", share: "0.2667" },
    { key: "__other__", label: "Others", color_token: null, logo_path: null, total: "200.00", share: "0.1333" },
  ],
  series: [
    { month: "2026-08", total: "500.00", values: { cat_dining: "300.00", __uncategorized__: "200.00", __other__: "0.00" } },
    { month: "2026-09", total: "1000.00", values: { cat_dining: "600.00", __uncategorized__: "200.00", __other__: "200.00" } },
  ],
};

describe("splitChart", () => {
  it("keeps the server's groups, totals and shares in order, with positional data keys", () => {
    const c = splitChart(byCategory, "category");
    expect(c.empty).toBe(false);
    expect(c.series.map((s) => [s.dataKey, s.key, s.total, s.share])).toEqual([
      ["s0", "cat_dining", "900.00", "0.6000"],
      ["s1", "__uncategorized__", "400.00", "0.2667"],
      ["s2", "__other__", "200.00", "0.1333"],
    ]);
    expect(c.rows[1]).toEqual({ month: "2026-09", monthTotal: "1000.00", s0: 600, s1: 200, s2: 200 });
    expect(c.raw.get("2026-08")!.get("s0")).toBe("300.00");
  });

  it("colours categories by their own token, Uncategorised neutral, Others distinct", () => {
    const c = splitChart(byCategory, "category");
    expect(c.series[0]!.fill).toBe("var(--chart-cat-3)");
    expect(c.series[1]!.fill).toBe("var(--chart-uncategorized)");
    expect(c.series[2]!.fill).toBe(OTHER_FILL);
  });

  it("gives banks and merchants the palette by rank", () => {
    expect(splitFill("bank", "FAB", null, 0)).toBe("var(--chart-cat-1)");
    expect(splitFill("merchant", "mer_x", null, 13)).toBe("var(--chart-cat-14)");
    expect(splitFill("merchant", "mer_y", null, 17)).toBe("var(--chart-cat-2)");
    expect(splitFill("bank", "__other__", null, 3)).toBe(OTHER_FILL);
  });

  it("shows one Total series from the month totals when not split", () => {
    const c = splitChart(byCategory, "none");
    expect(c.series).toHaveLength(1);
    expect(c.series[0]!.key).toBe(TOTAL_KEY);
    expect(c.rows.map((r) => r.s0)).toEqual([500, 1000]);
    expect(c.raw.get("2026-09")!.get("s0")).toBe("1000.00");
  });

  it("treats a missing value as zero", () => {
    const c = splitChart({ ...byCategory, series: [{ month: "2026-10", total: "0.00", values: {} }] }, "category");
    expect(c.rows[0]).toMatchObject({ s0: 0, s1: 0, s2: 0 });
  });

  it("is empty only when the server proves it", () => {
    expect(splitChart({ ...byCategory, groups: [], total: "0.00", series: [] }, "category").empty).toBe(true);
    expect(splitChart({ ...byCategory, total: "0.00" }, "none").empty).toBe(true);
  });
});

describe("helpers", () => {
  it("reads month totals from the category grouping when not split", () => {
    expect(breakdownGroupFor("none")).toBe("category");
    expect(breakdownGroupFor("bank")).toBe("bank");
  });

  it("computes a display share of the month, clamped", () => {
    expect(monthShare("250.00", "1000.00")).toBe(0.25);
    expect(monthShare("10.00", "0.00")).toBeNull();
    expect(monthShare("-5.00", "100.00")).toBe(0);
    expect(monthShare(undefined, "100.00")).toBeNull();
  });

  it("turns YYYY-MM into a date for the month formatters", () => {
    expect(monthDate("2026-09")).toBe("2026-09-01");
    expect(monthDate("2026-09-15")).toBe("2026-09-15");
  });

  it("links category rows to Activity, not banks, merchants or Others", () => {
    expect(groupActivitySearch("category", "cat_dining", "2026-05-01", "2026-10-31")).toEqual({ from: "2026-05-01", to: "2026-10-31", category: "cat_dining" });
    expect(groupActivitySearch("category", "__uncategorized__", "2026-05-01", "2026-10-31")?.category).toBe("none");
    expect(groupActivitySearch("category", "__other__", "a", "b")).toBeNull();
    expect(groupActivitySearch("bank", "FAB", "a", "b")).toBeNull();
  });
});
