import { describe, expect, it } from "vitest";
import { activityFilter, type ActivitySearch } from "@/lib/activity-filters";
import { selectionArgs, selectionKey } from "./transactions";
import { keys } from "./keys";

const CAT = "cat_01k00000000000000000000000";

describe("activityFilter (the bulk RPCs' p_filter)", () => {
  it("keeps the filter keys and drops paging and the drawer", () => {
    const s: ActivitySearch = { from: "2026-08-01", to: "2026-08-31", category: CAT, status: "posted", source: "sms", q: "cafe", page: 3, size: 200, txn: "txn_x" };
    expect(activityFilter(s)).toEqual({ from: "2026-08-01", to: "2026-08-31", category: CAT, status: "posted", source: "sms", q: "cafe" });
  });

  it("passes 'none' through for uncategorised and drops a blank search", () => {
    expect(activityFilter({ category: "none", q: "   " })).toEqual({ category: "none" });
  });

  it("is an empty object (every transaction) with no filters", () => {
    expect(activityFilter({ page: 2 })).toEqual({});
  });
});

describe("selectionArgs", () => {
  it("sends ticked rows as p_txn_codes only", () => {
    expect(selectionArgs({ kind: "codes", codes: ["txn_b", "txn_a"] })).toEqual({ p_txn_codes: ["txn_b", "txn_a"] });
  });

  it("sends 'all matching' as p_filter only", () => {
    expect(selectionArgs({ kind: "filter", search: { q: "cafe", page: 2 } })).toEqual({ p_filter: { q: "cafe" } });
  });
});

describe("selectionKey", () => {
  it("does not depend on tick order", () => {
    expect(selectionKey({ kind: "codes", codes: ["txn_b", "txn_a"] })).toEqual(selectionKey({ kind: "codes", codes: ["txn_a", "txn_b"] }));
  });

  it("ignores paging for 'all matching'", () => {
    expect(selectionKey({ kind: "filter", search: { q: "x", page: 2 } })).toEqual(selectionKey({ kind: "filter", search: { q: "x" } }));
  });

  it("lives under the transactions domain, so a ledger change refreshes the total", () => {
    expect(keys.selectionSummary("p1", null).slice(0, 3)).toEqual(["p", "p1", "transactions"]);
  });
});
