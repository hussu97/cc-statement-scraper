import { describe, expect, it } from "vitest";
import { parseTrendFilterSearch, serializeTrendFilters, toggleCode, trendFilterCount, trendFilters, UNCATEGORIZED_KEY } from "./trend-filters";
import { insightsRouteSearch, parseInsightsSearch, withInsightsRange, withTrendFilters, withTrends } from "./search";

const CAT_A = `cat_${"a".repeat(26)}`;
const CAT_B = `cat_${"b".repeat(26)}`;
const CRD_A = `crd_${"0".repeat(26)}`;

describe("trend filter codec", () => {
  it("parses comma-joined codes, dropping invalid and duplicate values", () => {
    expect(
      parseTrendFilterSearch({
        cat: `${CAT_A},nope,${UNCATEGORIZED_KEY},${CAT_A}`,
        bank: "FAB,adcb,ENBD,TOOLONGBANKCODE",
        card: `${CRD_A},crd_short`,
        q: "  noon ",
      }),
    ).toEqual({ cat: `${CAT_A},${UNCATEGORIZED_KEY}`, bank: "FAB,ENBD", card: CRD_A, q: "noon" });
  });

  it("accepts arrays (a hand-written or JSON link) and drops empties", () => {
    expect(parseTrendFilterSearch({ cat: [CAT_B, 3, CAT_A], bank: [], card: "", q: "   " })).toEqual({ cat: `${CAT_B},${CAT_A}` });
    expect(parseTrendFilterSearch({})).toEqual({});
    expect(parseTrendFilterSearch({ q: 42 })).toEqual({ q: "42" });
  });

  it("caps the search length", () => {
    expect(parseTrendFilterSearch({ q: "x".repeat(500) }).q).toHaveLength(120);
  });

  it("round-trips between the URL form and filters", () => {
    const f = { categories: [CAT_A, UNCATEGORIZED_KEY], banks: ["FAB"], cards: [CRD_A], q: "careem" };
    expect(trendFilters(serializeTrendFilters(f))).toEqual(f);
    expect(trendFilters({})).toEqual({ categories: [], banks: [], cards: [] });
    expect(serializeTrendFilters({ categories: [], banks: [], cards: [], q: " " })).toEqual({});
  });

  it("counts every selected value and the search once", () => {
    expect(trendFilterCount({ categories: [CAT_A, CAT_B], banks: ["FAB"], cards: [], q: "x" })).toBe(4);
    expect(trendFilterCount({ categories: [], banks: [], cards: [] })).toBe(0);
  });

  it("carries the card type as ?inst=credit|debit and drops anything else (Phase 2c)", () => {
    expect(parseTrendFilterSearch({ inst: "debit" })).toEqual({ inst: "debit" });
    expect(parseTrendFilterSearch({ inst: "cash" })).toEqual({});
    const f = { categories: [], banks: [], cards: [], instrument: "credit_card" as const };
    expect(serializeTrendFilters(f)).toEqual({ inst: "credit" });
    expect(trendFilters(serializeTrendFilters(f))).toEqual(f);
    expect(trendFilterCount(f)).toBe(1);
  });

  it("toggles a code in a list", () => {
    expect(toggleCode([CAT_A], CAT_B)).toEqual([CAT_A, CAT_B]);
    expect(toggleCode([CAT_A, CAT_B], CAT_A)).toEqual([CAT_B]);
  });
});

describe("Insights search with trend filters", () => {
  it("the route returns a dropped key as undefined, so an invalid ?range or ?inst can't survive from the raw URL", () => {
    const s = insightsRouteSearch({ range: "this-month", inst: "cash", tab: "trends" });
    expect(s.tab).toBe("trends");
    expect("range" in s && s.range === undefined).toBe(true);
    expect("inst" in s && s.inst === undefined).toBe(true);
  });

  it("keeps filters alongside range, tab and trend options", () => {
    expect(parseInsightsSearch({ range: "ytd", group: "bank", cat: CAT_A, bank: "FAB", q: "noon" })).toEqual({
      range: "ytd",
      group: "bank",
      cat: CAT_A,
      bank: "FAB",
      q: "noon",
    });
  });

  it("replaces the filters, keeping everything else", () => {
    const s = parseInsightsSearch({ range: "ytd", grain: "week", cat: CAT_A, q: "old" });
    expect(withTrendFilters(s, { categories: [], banks: ["FAB"], cards: [CRD_A] })).toEqual({ range: "ytd", grain: "week", bank: "FAB", card: CRD_A });
    expect(withTrendFilters(s, { categories: [], banks: [], cards: [] })).toEqual({ range: "ytd", grain: "week" });
  });

  it("survives range and grouping changes", () => {
    const s = parseInsightsSearch({ cat: CAT_A, card: CRD_A });
    expect(withTrends(s, { group: "bank" })).toEqual({ group: "bank", cat: CAT_A, card: CRD_A });
    expect(withInsightsRange(s, { range: "ytd" })).toEqual({ range: "ytd", cat: CAT_A, card: CRD_A });
  });
});
