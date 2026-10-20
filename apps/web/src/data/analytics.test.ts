import { describe, expect, it } from "vitest";
import { OTHER_KEY, pivotSeries, seriesKey, spendFilterArgs, type SpendSeriesRow } from "./analytics";

const row = (bucket: string, group_key: string | null, group_label: string, amount: number, color_token: string | null = null) =>
  ({ bucket, group_key, group_label, color_token, amount, txn_count: 1 }) as SpendSeriesRow;

describe("seriesKey", () => {
  it("uses the group key, the server's Other group, or an encoded label", () => {
    expect(seriesKey({ group_key: "cat_1", group_label: "Dining" })).toBe("cat_1");
    expect(seriesKey({ group_key: null, group_label: "Other" })).toBe(OTHER_KEY);
    expect(seriesKey({ group_key: null, group_label: "Uncategorised" })).toBe("label_Uncategorised");
    // dots and brackets would read as property paths in a chart dataKey
    expect(seriesKey({ group_key: null, group_label: "NOON.COM [AE]" })).toBe("label_NOON%2ECOM%20%5BAE%5D");
  });
});

describe("pivotSeries", () => {
  it("pivots server rows without folding, largest first and Other last", () => {
    const p = pivotSeries([
      row("2026-06-01", null, "Other", 500),
      row("2026-05-01", "cat_a", "Dining", 100, "cat-1"),
      row("2026-05-01", null, "Uncategorised", 40),
      row("2026-06-01", "cat_a", "Dining", 50, "cat-1"),
      row("2026-06-01", "cat_b", "Travel", 300, "cat-2"),
    ]);
    expect(p.groups.map((g) => [g.key, g.label, g.color_token])).toEqual([
      ["cat_b", "Travel", "cat-2"],
      ["cat_a", "Dining", "cat-1"],
      ["label_Uncategorised", "Uncategorised", null],
      [OTHER_KEY, "Other", null],
    ]);
    expect(p.rows).toEqual([
      { bucket: "2026-05-01", cat_a: 100, label_Uncategorised: 40 },
      { bucket: "2026-06-01", [OTHER_KEY]: 500, cat_a: 50, cat_b: 300 },
    ]);
  });

  it("handles string amounts and empty input", () => {
    expect(pivotSeries([row("2026-05-01", "x", "X", "12.50" as unknown as number)]).rows).toEqual([{ bucket: "2026-05-01", x: 12.5 }]);
    expect(pivotSeries([])).toEqual({ rows: [], groups: [] });
  });
});

describe("spendFilterArgs", () => {
  const CAT_A = `cat_${"a".repeat(26)}`;
  const CAT_B = `cat_${"b".repeat(26)}`;
  const CRD = `crd_${"0".repeat(26)}`;

  it("sends nothing when unfiltered, so other callers' RPC calls are unchanged", () => {
    expect(spendFilterArgs(undefined)).toEqual({});
    expect(spendFilterArgs({ categories: [], banks: [], cards: [], q: "  " })).toEqual({});
  });

  it("maps each filter to its RPC argument, lists sorted for a stable query key", () => {
    expect(spendFilterArgs({ categories: [CAT_B, "__uncategorized__", CAT_A], banks: ["FAB", "ADCB"], cards: [CRD], q: " noon " })).toEqual({
      p_category_codes: ["__uncategorized__", CAT_A, CAT_B],
      p_bank_codes: ["ADCB", "FAB"],
      p_card_codes: [CRD],
      p_q: "noon",
    });
    expect(spendFilterArgs({ categories: [], banks: ["FAB"], cards: [] })).toEqual({ p_bank_codes: ["FAB"] });
    expect(spendFilterArgs({ categories: [], banks: [], cards: [], instrument: "debit_card" })).toEqual({ p_instruments: ["debit_card"] });
  });

  it("does not mutate the selection order", () => {
    const f = { categories: [CAT_B, CAT_A], banks: [], cards: [] };
    spendFilterArgs(f);
    expect(f.categories).toEqual([CAT_B, CAT_A]);
  });
});
