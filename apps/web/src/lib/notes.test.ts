import { describe, expect, it } from "vitest";
import {
  branchFormula,
  cleanDecimal,
  distanceMet,
  distanceText,
  levelLabel,
  isEnded,
  noteStatus,
  payoutRows,
  pct,
  seriesRows,
  maturityTableRows,
  calledLabel,
  calledNext,
  outcomeLabel,
  outcomeTone,
  returnText,
  sellFromMarket,
} from "./notes";

describe("wording", () => {
  it("statuses", () => {
    expect(noteStatus("autocalled").label).toBe("Called early");
    expect(noteStatus(undefined).label).toBe("Live");
    expect(noteStatus("called")).toEqual({ label: "Called by issuer", tone: "positive" });
    expect(noteStatus("credit_event")).toEqual({ label: "Credit event", tone: "danger" });
    expect(["autocalled", "called", "matured", "credit_event", "cancelled"].every(isEnded)).toBe(true);
    expect(["live", "awaiting_strike", null].some(isEnded)).toBe(false);
  });
  it("percentages", () => {
    expect(pct("98.00")).toBe("98%");
    expect(pct("-24.5")).toBe("−24.5%");
    expect(pct(null)).toBe("—");
    expect(pct("91.4655", 2)).toBe("91.47%");
    expect(pct("100.0000", 2)).toBe("100%");
  });
  it("distances", () => {
    expect(distanceText("7.46")).toBe("needs +7.46%");
    expect(distanceText("-6.67")).toBe("6.67% above");
    expect(distanceText("0")).toBe("at the level");
    expect(distanceMet("-0.3")).toBe(true);
    expect(distanceMet("0.3")).toBe(false);
  });
  it("level labels", () => {
    expect(levelLabel({ kind: "final", payout_pct: "100", settlement: "cash" })).toBe("At maturity ≥ this: 100%");
    expect(levelLabel({ kind: "coupon" })).toBe("Coupon barrier");
  });
  it("branch formulas", () => {
    expect(branchFormula({ intercept_pct: "100", slope: "0" })).toBe("100%");
    expect(branchFormula({ intercept_pct: "-24.5", slope: "1" })).toBe("WP − 24.5%");
    expect(branchFormula({ intercept_pct: "0", slope: "1.66666667" })).toBe("1.667 × WP");
    expect(branchFormula({ intercept_pct: "-45", slope: "1" })).toBe("WP − 45%");
  });
  it("payout rows, highest first", () => {
    expect(
      payoutRows([
        { min_worst_pct: "0", intercept_pct: "0", slope: "1", settlement: "cash" },
        { min_worst_pct: "100", intercept_pct: "181", slope: "0", settlement: "cash" },
        { min_worst_pct: "63.5", intercept_pct: "100", slope: "0", settlement: "cash" },
      ]),
    ).toEqual([
      { when: "Lowest stock ≥ 100%", pays: "181%", physical: false },
      { when: "Lowest stock 63.5% to 100%", pays: "100%", physical: false },
      { when: "Lowest stock below 63.5%", pays: "WP", physical: false },
    ]);
  });
});

describe("typed amounts", () => {
  it("cleans typed numbers", () => {
    expect(cleanDecimal("37,250.00")).toBe("37250.00");
    expect(cleanDecimal("98%")).toBe("98");
    expect(cleanDecimal("−24.5")).toBe("-24.5");
    expect(cleanDecimal("abc")).toBeNull();
  });
});

describe("chart and tables", () => {
  it("merges the series by date", () => {
    expect(seriesRows({ AMZN: [["2026-10-22", "100"], ["2026-10-23", "98.5"]], MSFT: [["2026-10-23", "101.25"]] })).toEqual([
      { date: "2026-10-22", AMZN: 100 },
      { date: "2026-10-23", AMZN: 98.5, MSFT: 101.25 },
    ]);
  });
  it("keeps every 10% and the branch levels", () => {
    const curve = Array.from({ length: 31 }, (_, i) => ({ worst_pct: String(i * 5), payout_pct: "0" }));
    const rows = maturityTableRows(curve, [
      { min_worst_pct: "63.5", intercept_pct: "100", slope: "0", settlement: "cash" },
      { min_worst_pct: "45", intercept_pct: "-45", slope: "1", settlement: "cash" },
      { min_worst_pct: "0", intercept_pct: "0", slope: "1", settlement: "cash" },
    ]).map((r) => r.worst_pct);
    expect(rows).toEqual(["0", "10", "20", "30", "40", "45", "50", "60", "70", "80", "90", "100", "110", "120", "130", "140", "150"]);
  });
});

describe("outcome kinds", () => {
  it("labels known kinds, including a coupon paid before the purchase", () => {
    expect(outcomeLabel("coupon")).toBe("Coupon paid");
    expect(outcomeLabel("coupon_before_purchase")).toBe("Before purchase");
    expect(outcomeTone("coupon")).toBe("positive");
    expect(outcomeTone("autocall")).toBe("positive");
    expect(outcomeTone("coupon_before_purchase")).toBe("muted");
    expect(outcomeTone("maturity")).toBe("muted");
  });
  it("never breaks on a kind it doesn't know", () => {
    expect(outcomeLabel("partial_redemption")).toBe("Partial redemption");
    expect(outcomeLabel(null)).toBe("Outcome");
    expect(outcomeTone("partial_redemption")).toBe("muted");
  });
});

describe("sell today or if called", () => {
  it("reads the market quote as sell-today", () => {
    expect(sellFromMarket({ price_pct: "90", value: "9000.00", as_of: "2026-10-27", profit: "-1000.00" })).toEqual({
      total: "9000.00",
      profit: "-1000.00",
      returnPct: null,
      pricePct: "90",
      asOf: "2026-10-27",
    });
    expect(sellFromMarket(null)).toBeNull();
    expect(sellFromMarket(undefined)).toBeNull();
  });
  it("reads the first autocall as if-called", () => {
    const c = calledNext({
      obs_date: "2027-03-15",
      pay_date: "2027-03-22",
      trigger_pct: "100",
      redemption_pct: "110",
      redemption: "11000.00",
      coupons: "0.00",
      total: "11000.00",
      profit: "1000.00",
      return_pct: "10.00",
      annualised_pct: "20.00",
    })!;
    expect(c).toEqual({ obsDate: "2027-03-15", payDate: "2027-03-22", total: "11000.00", profit: "1000.00", returnPct: "10.00", annualisedPct: "20.00", triggerPct: "100" });
    expect(calledLabel(c)).toBe("If called 22 Mar 2027");
    expect(calledLabel(c, "short")).toBe("If called 22 Mar");
    expect(calledNext(null)).toBeNull();
  });
  it("words a return", () => {
    expect(returnText("10.00", "20.00")).toBe("10% · 20% a year");
    expect(returnText("15.321")).toBe("15.32%");
    expect(returnText(null)).toBe("—");
  });
});
