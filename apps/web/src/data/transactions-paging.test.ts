import { describe, expect, it } from "vitest";
import { listFilters } from "./transactions";
import { parseActivitySearch, withFilter } from "@/lib/activity-filters";

describe("listFilters (an infinite list's identity)", () => {
  it("drops paging and the open drawer, keeps every filter", () => {
    const s = parseActivitySearch({ q: "coffee", status: "posted", page: "3", size: "500", txn: "txn_01k4ea5wxd4v7q0k6gw13ejsny" });
    expect(listFilters(s)).toEqual({ q: "coffee", status: "posted" });
  });

  it("is the same list on every page, and a new list when a filter changes", () => {
    const a = parseActivitySearch({ q: "coffee", page: "2" });
    const b = parseActivitySearch({ q: "coffee", page: "7" });
    expect(listFilters(a)).toEqual(listFilters(b));
    expect(listFilters(withFilter(a, { status: "pending" }))).not.toEqual(listFilters(a));
  });

  it("a filter change also resets the numbered page", () => {
    expect(withFilter(parseActivitySearch({ page: "4", size: "200" }), { q: "x" })).toEqual({ q: "x", size: 200 });
  });
});
