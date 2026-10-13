import { describe, expect, it } from "vitest";
import {
  budgetDraft,
  budgetPace,
  budgetTitle,
  budgetTone,
  dateToMonthInput,
  inactiveBudgetLabel,
  monthInputToDate,
  monthPhase,
  splitByEffective,
  validateBudget,
} from "./budgets";

describe("budgetTone", () => {
  const b = (share_used: number, projected_aed: number, budget_aed = 1000) => ({ share_used, projected_aed, budget_aed });
  it("is positive while comfortably under", () => {
    expect(budgetTone(b(0.4, 900), true)).toBe("positive");
  });
  it("warns from 80% used", () => {
    expect(budgetTone(b(0.8, 900), true)).toBe("warn");
    expect(budgetTone(b(1, 1000), false)).toBe("warn");
  });
  it("warns when this month is on pace to overspend", () => {
    expect(budgetTone(b(0.5, 1200), true)).toBe("warn");
    expect(budgetTone(b(0.5, 1200), false)).toBe("positive");
  });
  it("is danger once over budget", () => {
    expect(budgetTone(b(1.01, 1500), true)).toBe("danger");
  });
});

describe("budgetPace (WEB-38)", () => {
  it("says how far over the expected-by-today share, from the server's figures", () => {
    expect(budgetPace({ expected_share: "0.4194", expected_aed: "503.23", over_pace_aed: "120.40" })).toEqual({
      tickAt: 0.4194,
      label: "AED 120 over pace",
      over: true,
      expected: "AED 503 expected by today",
    });
  });
  it("says under pace, and on pace at exactly zero", () => {
    expect(budgetPace({ expected_share: 0.5, expected_aed: 600, over_pace_aed: "-80.00" })).toMatchObject({ label: "AED 80 under pace", over: false });
    expect(budgetPace({ expected_share: 0.5, expected_aed: 600, over_pace_aed: "0.00" })).toMatchObject({ label: "On pace", over: false });
    expect(budgetPace({ expected_share: 0.5, expected_aed: 600, over_pace_aed: "0.40" })).toMatchObject({ label: "AED 0.40 over pace", over: true });
  });
  it("has nothing to say outside the current month, or from an older server", () => {
    expect(budgetPace({ expected_share: null, expected_aed: null, over_pace_aed: null })).toEqual({ tickAt: null, label: null, over: false, expected: null });
    expect(budgetPace({})).toEqual({ tickAt: null, label: null, over: false, expected: null });
  });
});

describe("month helpers", () => {
  it("classifies months against today", () => {
    expect(monthPhase("2026-09-01", "2026-10-08")).toBe("past");
    expect(monthPhase("2026-10-01", "2026-10-08")).toBe("current");
    expect(monthPhase("2026-11-01", "2026-10-08")).toBe("future");
  });
  it("converts month inputs", () => {
    expect(monthInputToDate("2026-10")).toBe("2026-10-01");
    expect(monthInputToDate("2026-13")).toBe("");
    expect(monthInputToDate("")).toBe("");
    expect(dateToMonthInput("2026-10-01")).toBe("2026-10");
    expect(dateToMonthInput(null)).toBe("");
  });
  it("validates month-input dates through validateBudget", () => {
    const base = { account_code: null, category_code: null, amount_aed: "1500", effective_to: null };
    expect(validateBudget({ ...base, effective_from: monthInputToDate("2026-10") })).toBeNull();
    expect(validateBudget({ ...base, effective_from: monthInputToDate("") })).toMatch(/first of a month/);
  });
});

describe("budgetTitle", () => {
  it("names every-card budgets by category", () => {
    expect(budgetTitle({ category_code: null, category_name: "All spending", account_name: null })).toBe("All spending");
    expect(budgetTitle({ category_code: "cat_1", category_name: "Dining", account_name: null })).toBe("Dining");
  });
  it("names card budgets by card, and by category on that card", () => {
    expect(budgetTitle({ category_code: null, category_name: "All spending", account_name: "FAB · Platinum" })).toBe("FAB · Platinum");
    expect(budgetTitle({ category_code: "cat_1", category_name: "Dining", account_name: "Daily card" })).toBe("Dining · Daily card");
  });
});

describe("budgets the server says don't count", () => {
  const row = (budget_code: string, is_effective: boolean) => ({ budget_code, is_effective });
  it("splits rows by is_effective and keeps the server's order", () => {
    const { effective, inactive } = splitByEffective([row("a", true), row("b", true), row("c", false), row("d", false)]);
    expect(effective.map((r) => r.budget_code)).toEqual(["a", "b"]);
    expect(inactive.map((r) => r.budget_code)).toEqual(["c", "d"]);
    expect(splitByEffective([])).toEqual({ effective: [], inactive: [] });
  });
  it("labels an upcoming budget by its start month", () => {
    expect(inactiveBudgetLabel({ effective_from: "2026-11-01", effective_to: null }, "2026-10-01")).toBe("Starts November 2026");
  });
  it("labels an ended budget by its last month", () => {
    expect(inactiveBudgetLabel({ effective_from: "2026-01-01", effective_to: "2026-08-01" }, "2026-10-01")).toBe("Ended August 2026");
  });
  it("calls a not-effective budget whose range covers the month replaced (the server picked a newer one)", () => {
    expect(inactiveBudgetLabel({ effective_from: "2026-01-01", effective_to: null }, "2026-10-01")).toBe("Replaced by a newer budget");
    expect(inactiveBudgetLabel({ effective_from: "2026-01-01", effective_to: "2026-10-01" }, "2026-10-01")).toBe("Replaced by a newer budget");
  });
});

describe("budgetDraft", () => {
  it("starts the edit form from a budget_status row", () => {
    expect(
      budgetDraft({ budget_code: "bud_1", account_code: "acc_1", category_code: null, budget_aed: 1500.5, effective_from: "2026-10-01", effective_to: null }),
    ).toEqual({ budget_code: "bud_1", account_code: "acc_1", category_code: null, amount_aed: "1500.5", effective_from: "2026-10-01", effective_to: null });
  });
});
