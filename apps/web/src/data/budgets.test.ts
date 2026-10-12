import { describe, expect, it } from "vitest";
import { budgetAppliesTo, budgetTitle, budgetTone, dateToMonthInput, monthInputToDate, monthPhase, validateBudget } from "./budgets";

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
  it("checks whether a budget covers a month", () => {
    expect(budgetAppliesTo({ effective_from: "2026-01-01", effective_to: null }, "2026-10-01")).toBe(true);
    expect(budgetAppliesTo({ effective_from: "2026-01-01", effective_to: "2026-10-01" }, "2026-10-01")).toBe(true);
    expect(budgetAppliesTo({ effective_from: "2026-01-01", effective_to: "2026-09-01" }, "2026-10-01")).toBe(false);
    expect(budgetAppliesTo({ effective_from: "2026-11-01", effective_to: null }, "2026-10-01")).toBe(false);
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
