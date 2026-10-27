import { describe, expect, it } from "vitest";
import {
  branchFormula,
  cleanDecimal,
  createNoteDraft,
  distanceMet,
  distanceText,
  draftProblems,
  levelLabel,
  noteStatus,
  payoutRows,
  pct,
  scheduleSummary,
  seriesRows,
  maturityTableRows,
  type InvestmentForm,
  type NoteDraft,
} from "./notes";

const DRAFT: NoteDraft = {
  name: "Marex Phoenix GOOGL/AMZN/JPM/MSFT 2030",
  termsheet_path: "prf_x/abc.pdf",
  termsheet_filename: "marex.pdf",
  terms: {
    product_name: "47 Months USD Worst of Memory Phoenix Autocall",
    isin: "XS3536529152",
    issuer: "Marex Financial",
    guarantor: null,
    currency: "usd",
    denomination: "1000",
    issue_price_pct: "74.5",
    strike_date: "2026-10-22",
    issue_date: "2026-11-13",
    final_valuation_date: "2030-10-22",
    maturity_date: "2030-10-29",
    underlyings: [{ name: "Alphabet Inc", symbol: "googl", bloomberg_code: "GOOGL UW Equity", isin: null, exchange: null, initial_level: "324.22" }],
    observations: [
      { obs_date: "2026-11-23", pay_date: "2026-12-01", coupon_rate_pct: "0.667", coupon_barrier_pct: "98", coupon_memory: true, autocall_trigger_pct: null, autocall_amount_pct: null },
      { obs_date: "2027-04-22", pay_date: "2027-04-29", coupon_rate_pct: "0.667", coupon_barrier_pct: "98", coupon_memory: true, autocall_trigger_pct: "105", autocall_amount_pct: "100" },
    ],
    payout: [
      { min_worst_pct: "100", intercept_pct: "100", slope: "0", settlement: "cash" },
      { min_worst_pct: "0", intercept_pct: "-24.5", slope: "1", settlement: "physical" },
    ],
  },
};
const INV: InvestmentForm = { invested_amount: "37,250.00", purchase_price_pct: "", nominal: "", trade_date: "2026-10-22", funding_account_code: "acc_1" };

describe("wording", () => {
  it("statuses", () => {
    expect(noteStatus("autocalled").label).toBe("Called early");
    expect(noteStatus(undefined).label).toBe("Live");
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
      { when: "Worst ≥ 100%", pays: "181%", physical: false },
      { when: "Worst 63.5% to 100%", pays: "100%", physical: false },
      { when: "Worst below 63.5%", pays: "WP", physical: false },
    ]);
  });
  it("schedule summary", () => {
    expect(scheduleSummary(DRAFT.terms.observations)).toBe("2 coupons of 0.667% (98% barrier, memory) · 1 autocall date from 22 Apr 2027 at 105%");
  });
});

describe("the review form", () => {
  it("cleans typed numbers", () => {
    expect(cleanDecimal("37,250.00")).toBe("37250.00");
    expect(cleanDecimal("98%")).toBe("98");
    expect(cleanDecimal("−24.5")).toBe("-24.5");
    expect(cleanDecimal("abc")).toBeNull();
  });
  it("accepts the extracted Marex sheet", () => {
    expect(draftProblems(DRAFT, INV)).toEqual([]);
  });
  it("names what is missing", () => {
    const bad: NoteDraft = {
      ...DRAFT,
      terms: { ...DRAFT.terms, underlyings: [{ ...DRAFT.terms.underlyings[0]!, symbol: "" }], payout: [DRAFT.terms.payout[0]!] },
    };
    expect(draftProblems(bad, { ...INV, invested_amount: "1.234" })).toEqual([
      "Alphabet Inc: enter its price symbol (e.g. AMZN).",
      "The payout needs a branch from 0%: what is paid however far the worst share falls.",
      "Enter how much you invested (up to 2 decimals).",
    ]);
  });
  it("builds create_structured_note's draft", () => {
    const d = createNoteDraft(DRAFT, INV, "Swissquote") as { terms: Record<string, unknown>; investment: Record<string, unknown> };
    expect(d.terms.currency).toBe("USD");
    expect((d.terms.underlyings as { symbol: string }[])[0]?.symbol).toBe("GOOGL");
    expect((d.terms.observations as { autocall_trigger_pct: string | null }[]).map((o) => o.autocall_trigger_pct)).toEqual([null, "105"]);
    expect(d.investment).toEqual({ invested_amount: "37250.00", purchase_price_pct: null, nominal: null, trade_date: "2026-10-22", funding_account_code: "acc_1" });
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
