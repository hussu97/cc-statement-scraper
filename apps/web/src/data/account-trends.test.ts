import { describe, expect, it } from "vitest";
import { comparisonRange, monthlySpendByAccount, monthsBetween, sparkValues, statementTrends } from "./account-trends";
import type { StatementCycle } from "./cards";
import type { SpendSeriesRow } from "./analytics";

const cycle = (account_code: string, statement_date: string, closing_balance: number | null, utilisation: number | null, kind = "statement") =>
  ({ stmt_code: `stm_${account_code}_${statement_date}`, account_code, statement_date, closing_balance, utilisation, credit_limit: 10000, kind }) as unknown as StatementCycle;

const row = (bucket: string, group_key: string | null, amount: number | string) => ({ bucket, group_key, group_label: "x", color_token: null, amount, txn_count: 1 }) as unknown as SpendSeriesRow;

describe("comparisonRange / monthsBetween", () => {
  it("covers the last 12 whole months to today", () => {
    expect(comparisonRange("2026-10-13")).toEqual({ from: "2025-11-01", to: "2026-10-13" });
    expect(comparisonRange("2026-01-31", 3)).toEqual({ from: "2025-11-01", to: "2026-01-31" });
  });

  it("lists month starts, oldest first, across a year end", () => {
    expect(monthsBetween("2025-11-01", "2026-02-13")).toEqual(["2025-11-01", "2025-12-01", "2026-01-01", "2026-02-01"]);
    expect(monthsBetween("2026-10-05", "2026-10-13")).toEqual(["2026-10-01"]);
  });
});

describe("statementTrends", () => {
  it("keeps each account's newest statements, oldest first, without history exports", () => {
    const t = statementTrends(
      [
        cycle("acc_a", "2026-09-25", 900, 0.09),
        cycle("acc_b", "2026-09-05", 50, null),
        cycle("acc_a", "2026-07-25", 700, 0.07),
        cycle("acc_a", "2026-08-25", 800, 0.08),
        cycle("acc_a", "2026-06-25", 600, 0.06),
        cycle("acc_a", "2026-10-01", 1, 0, "history_export"),
      ],
      3,
    );
    expect(t.get("acc_a")!.map((p) => [p.statement_date, p.closing_balance, p.utilisation])).toEqual([
      ["2026-07-25", 700, 0.07],
      ["2026-08-25", 800, 0.08],
      ["2026-09-25", 900, 0.09],
    ]);
    expect(t.get("acc_b")!.map((p) => p.statement_date)).toEqual(["2026-09-05"]);
    expect(t.has("acc_c")).toBe(false);
  });
});

describe("monthlySpendByAccount", () => {
  const months = ["2026-08-01", "2026-09-01", "2026-10-01"];

  it("puts the server's amounts on every month, a month without a row being 0", () => {
    const m = monthlySpendByAccount([row("2026-08-01", "acc_a", "120.50"), row("2026-10-01", "acc_a", 30), row("2026-09-01", "acc_b", 5)], months);
    expect(m.get("acc_a")).toEqual([
      { month: "2026-08-01", amount: "120.50" },
      { month: "2026-09-01", amount: 0 },
      { month: "2026-10-01", amount: 30 },
    ]);
    expect(m.get("acc_b")!.map((p) => p.amount)).toEqual([0, 5, 0]);
  });

  it("ignores rows without an account and has no entry for an account without spend", () => {
    const m = monthlySpendByAccount([row("2026-08-01", null, 10)], months);
    expect(m.size).toBe(0);
  });
});

describe("sparkValues", () => {
  it("turns server amounts into numbers, a missing one into a gap", () => {
    expect(sparkValues(["1,200.50", 3, null, undefined, ""])).toEqual([1200.5, 3, null, null, null]);
  });
});
