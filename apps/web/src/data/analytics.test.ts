import { describe, expect, it } from "vitest";
import { OTHER_KEY, pivotSeries, seriesKey, type SpendSeriesRow } from "./analytics";

const row = (bucket: string, group_key: string | null, group_label: string, amount: number, color_token: string | null = null) =>
  ({ bucket, group_key, group_label, color_token, amount, txn_count: 1 }) as SpendSeriesRow;

describe("seriesKey", () => {
  it("uses the group key, the server's Other group, or an encoded label", () => {
    expect(seriesKey({ group_key: "cat_1", group_label: "Dining" })).toBe("cat_1");
    expect(seriesKey({ group_key: null, group_label: "Other" })).toBe(OTHER_KEY);
    expect(seriesKey({ group_key: null, group_label: "Uncategorized" })).toBe("label_Uncategorized");
    // dots and brackets would read as property paths in a chart dataKey
    expect(seriesKey({ group_key: null, group_label: "NOON.COM [AE]" })).toBe("label_NOON%2ECOM%20%5BAE%5D");
  });
});

describe("pivotSeries", () => {
  it("pivots server rows without folding, largest first and Other last", () => {
    const p = pivotSeries([
      row("2026-06-01", null, "Other", 500),
      row("2026-05-01", "cat_a", "Dining", 100, "cat-1"),
      row("2026-05-01", null, "Uncategorized", 40),
      row("2026-06-01", "cat_a", "Dining", 50, "cat-1"),
      row("2026-06-01", "cat_b", "Travel", 300, "cat-2"),
    ]);
    expect(p.groups.map((g) => [g.key, g.label, g.color_token])).toEqual([
      ["cat_b", "Travel", "cat-2"],
      ["cat_a", "Dining", "cat-1"],
      ["label_Uncategorized", "Uncategorized", null],
      [OTHER_KEY, "Other", null],
    ]);
    expect(p.rows).toEqual([
      { bucket: "2026-05-01", cat_a: 100, label_Uncategorized: 40 },
      { bucket: "2026-06-01", [OTHER_KEY]: 500, cat_a: 50, cat_b: 300 },
    ]);
  });

  it("handles string amounts and empty input", () => {
    expect(pivotSeries([row("2026-05-01", "x", "X", "12.50" as unknown as number)]).rows).toEqual([{ bucket: "2026-05-01", x: 12.5 }]);
    expect(pivotSeries([])).toEqual({ rows: [], groups: [] });
  });
});
