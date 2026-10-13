import { describe, expect, it } from "vitest";
import { DAY_TOTALS_MAX_DAYS, dayTotalLabel, groupByDay, listDays } from "./transactions";
import { keys } from "./keys";

describe("listDays (activity_day_totals' p_days)", () => {
  it("is the page's distinct days in list order", () => {
    const groups = groupByDay([{ txn_date: "2026-09-03" }, { txn_date: "2026-09-03" }, { txn_date: "2026-08-31" }]);
    expect(listDays(groups)).toEqual(["2026-09-03", "2026-08-31"]);
  });
  it("drops a row without a date and repeats nothing", () => {
    expect(listDays([{ day: "2026-09-03" }, { day: "" }, { day: "2026-09-03" }])).toEqual(["2026-09-03"]);
  });
  it("stays within the server's limit", () => {
    const many = Array.from({ length: DAY_TOTALS_MAX_DAYS + 5 }, (_, i) => ({ day: `d${i}` }));
    expect(listDays(many)).toHaveLength(DAY_TOTALS_MAX_DAYS);
  });
  it("is empty for an empty page", () => {
    expect(listDays([])).toEqual([]);
  });
});

describe("dayTotalLabel", () => {
  it("shows the server's net as a whole-unit total", () => {
    expect(dayTotalLabel({ net_aed: "105.50", has_estimate: false })).toBe("AED 106");
  });
  it("shows a day of refunds as negative", () => {
    expect(dayTotalLabel({ net_aed: "-20.00", has_estimate: false })).toBe("−AED 20");
  });
  it("marks an estimated rate", () => {
    expect(dayTotalLabel({ net_aed: "40.00", has_estimate: true })).toBe("≈ AED 40");
  });
  it("says nothing without a server total", () => {
    expect(dayTotalLabel(undefined)).toBeNull();
  });
});

describe("keys.dayTotals", () => {
  it("lives under the transactions domain, so a ledger change refreshes it", () => {
    expect(keys.dayTotals("prf_x", { q: "cafe" }, ["2026-09-03", "2026-08-31"]).slice(0, 4)).toEqual(["p", "prf_x", "transactions", "days"]);
  });
  it("changes with the page's days", () => {
    expect(keys.dayTotals("prf_x", {}, ["2026-09-03"])).not.toEqual(keys.dayTotals("prf_x", {}, ["2026-09-02"]));
  });
});
