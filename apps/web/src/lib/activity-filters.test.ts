import { describe, expect, it } from "vitest";
import { activeFilterCount, ilikePattern, listSearch, parseActivitySearch, withFilter } from "./activity-filters";
import { pageCount, pageRange, normalizePageSize } from "./pagination";

const ACC = "acc_01hzzzzzzzzzzzzzzzzzzzzzzz";
const CAT = "cat_01hzzzzzzzzzzzzzzzzzzzzzzz";
const TXN = "txn_01hzzzzzzzzzzzzzzzzzzzzzzz";

describe("activity search codec", () => {
  it("keeps valid params and drops junk", () => {
    expect(
      parseActivitySearch({ from: "2026-10-01", to: "2026-10-31", account: ACC, category: CAT, status: "pending", source: "both", q: "  coffee ", page: "2", size: "500" }),
    ).toEqual({ from: "2026-10-01", to: "2026-10-31", account: ACC, category: CAT, status: "pending", source: "both", q: "coffee", page: 2, size: 500 });
    expect(parseActivitySearch({ from: "yesterday", account: "acc_bad", status: "weird", source: "x", page: "-1", size: "7", category: "drop table" })).toEqual({});
  });

  it("accepts the uncategorised sentinel and the drawer txn", () => {
    expect(parseActivitySearch({ category: "none", txn: TXN })).toEqual({ category: "none", txn: TXN });
  });

  it("swaps an inverted range and omits defaults", () => {
    expect(parseActivitySearch({ from: "2026-10-31", to: "2026-10-01", page: 1, size: 100 })).toEqual({ from: "2026-10-01", to: "2026-10-31" });
  });

  it("resets the page when a filter changes", () => {
    expect(withFilter({ page: 3, q: "a" }, { status: "posted" })).toEqual({ q: "a", status: "posted" });
    expect(withFilter({ q: "a" }, { q: undefined })).toEqual({});
  });

  it("counts filters and strips the drawer param for list keys", () => {
    expect(activeFilterCount({ from: "2026-10-01", q: "x", page: 2 })).toBe(2);
    expect(listSearch({ q: "x", txn: TXN })).toEqual({ q: "x" });
  });

  it("escapes ilike wildcards and PostgREST separators", () => {
    expect(ilikePattern("50%_off")).toBe("%50\\%\\_off%");
    expect(ilikePattern("a,b(c)")).toBe("%a b c %");
  });
});

describe("pagination", () => {
  it("uses the house page sizes", () => {
    expect(normalizePageSize("200")).toBe(200);
    expect(normalizePageSize(50)).toBe(100);
    expect(pageRange(1, 100)).toEqual({ from: 0, to: 99 });
    expect(pageRange(3, 200)).toEqual({ from: 400, to: 599 });
    expect(pageCount(0, 100)).toBe(1);
    expect(pageCount(497, 100)).toBe(5);
  });
});
