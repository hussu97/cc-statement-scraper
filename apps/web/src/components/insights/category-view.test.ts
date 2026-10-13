import { describe, expect, it } from "vitest";
import { breakdownRowFor, categoryFilterKey, categoryParam, isCategoryParam, merchantActivitySearch, trendRange } from "./category-view";

const CAT = "cat_01k6x9b0f3h2j4k5m6n7p8q9rs";
const range = { from: "2026-05-01", to: "2026-10-31" };

describe("category view helpers", () => {
  it("accepts a category code or 'none' in the URL, and nothing else", () => {
    expect(isCategoryParam(CAT)).toBe(true);
    expect(isCategoryParam("none")).toBe(true);
    expect(isCategoryParam("__uncategorized__")).toBe(false);
    expect(isCategoryParam("cat_short")).toBe(false);
    expect(isCategoryParam("mer_01k6x9b0f3h2j4k5m6n7p8q9rs")).toBe(false);
    expect(isCategoryParam(undefined)).toBe(false);
  });

  it("maps uncategorised between the URL, the rows and the spend filters", () => {
    expect(categoryParam(null)).toBe("none");
    expect(categoryParam(CAT)).toBe(CAT);
    expect(categoryFilterKey("none")).toBe("__uncategorized__");
    expect(categoryFilterKey(CAT)).toBe(CAT);
  });

  it("finds the breakdown row for a URL code, or null when it had no spend", () => {
    const rows = [
      { category_code: CAT, amount: 10 },
      { category_code: null, amount: 5 },
    ];
    expect(breakdownRowFor(rows, CAT)).toBe(rows[0]);
    expect(breakdownRowFor(rows, "none")).toBe(rows[1]);
    expect(breakdownRowFor(rows, "cat_01k6x9b0f3h2j4k5m6n7p8q9zz")).toBeNull();
  });

  it("links a top merchant to Activity by category, range and name; never Others or Unknown", () => {
    expect(merchantActivitySearch({ key: "mer_01k6x9b0f3h2j4k5m6n7p8q9rs", label: "  Carrefour " }, CAT, range)).toEqual({
      category: CAT,
      from: "2026-05-01",
      to: "2026-10-31",
      q: "Carrefour",
    });
    expect(merchantActivitySearch({ key: "__other__", label: "Others" }, CAT, range)).toBeNull();
    expect(merchantActivitySearch({ key: "__unknown__", label: "Unknown merchant" }, "none", range)).toBeNull();
    expect(merchantActivitySearch({ key: "mer_x", label: "  " }, CAT, range)).toBeNull();
  });

  it("widens a short range to six whole months for the trend, and keeps a longer one", () => {
    expect(trendRange({ from: "2026-10-01", to: "2026-10-31" })).toEqual({ from: "2026-05-01", to: "2026-10-31" });
    expect(trendRange({ from: "2026-10-10", to: "2026-10-12" })).toEqual({ from: "2026-05-01", to: "2026-10-12" });
    expect(trendRange(range)).toEqual(range);
    expect(trendRange({ from: "2025-11-01", to: "2026-10-31" })).toEqual({ from: "2025-11-01", to: "2026-10-31" });
    expect(trendRange({ from: "2026-02-15", to: "2026-03-10" }, 3)).toEqual({ from: "2026-01-01", to: "2026-03-10" });
  });
});
