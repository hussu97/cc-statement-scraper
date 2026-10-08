import { describe, expect, it } from "vitest";
import { flattenUnique, INFINITE_PAGE_SIZE, INFINITE_QUERY, latestTotal, nextOffset, pagePatch, parsePageSearch, sizePatch } from "./infinite";

const page = (ids: number[], total: number) => ({ rows: ids.map((id) => ({ id: `r${id}` })), total });
const range = (from: number, n: number) => Array.from({ length: n }, (_, i) => from + i);

describe("nextOffset", () => {
  it("starts at 0 and advances by the rows the server returned", () => {
    expect(nextOffset([], 100)).toBe(0);
    expect(nextOffset([page(range(0, 100), 250)], 100)).toBe(100);
    expect(nextOffset([page(range(0, 100), 250), page(range(100, 100), 250)], 100)).toBe(200);
  });

  it("ends on a short page, an empty page, or when the total is reached", () => {
    expect(nextOffset([page(range(0, 100), 250), page(range(100, 100), 250), page(range(200, 50), 250)], 100)).toBeUndefined();
    expect(nextOffset([page(range(0, 100), 100)], 100)).toBeUndefined();
    expect(nextOffset([page([], 0)], 100)).toBeUndefined();
    // The set shrank while scrolling: a total below what is loaded ends the list.
    expect(nextOffset([page(range(0, 100), 90)], 100)).toBeUndefined();
  });
});

describe("flattenUnique", () => {
  it("keeps server order and drops rows repeated across pages", () => {
    // A new row at the top shifted the offsets: page 2 starts with page 1's last row.
    const out = flattenUnique([page([1, 2, 3], 7), page([3, 4, 5], 7)], (r) => r.id);
    expect(out.map((r) => r.id)).toEqual(["r1", "r2", "r3", "r4", "r5"]);
  });

  it("keeps rows without an id", () => {
    const pages = [{ rows: [{ id: null }, { id: "a" }, { id: null }], total: 3 }];
    expect(flattenUnique(pages, (r) => r.id)).toHaveLength(3);
  });

  it("reports the newest total", () => {
    expect(latestTotal([])).toBeUndefined();
    expect(latestTotal([page([1], 10), page([2], 12)])).toBe(12);
  });
});

describe("page search codec", () => {
  it("keeps valid page and size, drops defaults and junk", () => {
    expect(parsePageSearch({ page: "3", size: "500" })).toEqual({ page: 3, size: 500 });
    expect(parsePageSearch({ page: 1, size: 100 })).toEqual({});
    expect(parsePageSearch({ page: "-2", size: "37" })).toEqual({});
    expect(parsePageSearch({})).toEqual({});
  });

  it("moving page drops page 1; a new size goes back to page 1", () => {
    expect(pagePatch(1)).toEqual({ page: undefined });
    expect(pagePatch(4)).toEqual({ page: 4 });
    expect(sizePatch(100)).toEqual({ page: undefined, size: undefined });
    expect(sizePatch(2000)).toEqual({ page: undefined, size: 2000 });
  });

  it("phones load the standard page of 100", () => {
    expect(INFINITE_PAGE_SIZE).toBe(100);
    expect(INFINITE_QUERY).toBe("(max-width: 767px)");
  });
});
