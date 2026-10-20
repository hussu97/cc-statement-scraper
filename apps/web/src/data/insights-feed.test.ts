import { describe, expect, it } from "vitest";
import { groupInsights, INSIGHT_GROUPS, insightTarget, isWealthInsight, WEALTH_INSIGHT_KINDS } from "./overview";

const i = (kind: string, severity: string, created_at: string) => ({ kind, severity, created_at, insight_code: `${kind}-${created_at}` });

describe("groupInsights (MA-5)", () => {
  it("sections insights by the screen that answers them, in a fixed order, alerts first", () => {
    const groups = groupInsights([
      i("review_backlog", "info", "2026-10-10"),
      i("budget_risk", "warn", "2026-10-09"),
      i("large_transaction", "info", "2026-10-12"),
      i("cash_advance", "warn", "2026-10-13"),
      i("category_spike", "alert", "2026-10-01"),
      i("statement_due", "warn", "2026-10-11"),
      i("price_change", "info", "2026-10-02"),
      i("uncategorized", "warn", "2026-10-03"),
    ]);
    expect(groups.map((g) => [g.key, g.label, g.items.map((x) => x.kind)])).toEqual([
      ["spending", "Spending", ["category_spike", "cash_advance", "large_transaction"]],
      ["budgets", "Budgets", ["budget_risk"]],
      ["subscriptions", "Subscriptions", ["price_change"]],
      ["statements", "Cards and statements", ["statement_due"]],
      ["tidy", "To tidy up", ["uncategorized", "review_backlog"]],
    ]);
  });

  it("keeps a kind the web doesn't know in Other, last", () => {
    const groups = groupInsights([i("something_new", "info", "2026-10-01"), i("spend_pace", "warn", "2026-10-02")]);
    expect(groups.map((g) => g.key)).toEqual(["spending", "other"]);
    expect(groups[1]!.items[0]!.kind).toBe("something_new");
  });

  it("leaves out empty sections, and returns nothing for no insights", () => {
    expect(groupInsights([])).toEqual([]);
  });

  it("covers every kind the server's CHECK allows: Spending's feed sections plus Wealth's kinds, once each", () => {
    const serverKinds = [
      "spend_pace", "category_spike", "budget_risk", "price_change", "new_recurring", "statement_due", "uncategorized", "review_backlog", "large_transaction", "cash_advance",
      "balance_stale", "balance_drift", "salary_late", "annual_fee",
    ];
    const grouped = [...INSIGHT_GROUPS.flatMap((g) => [...g.kinds]), ...WEALTH_INSIGHT_KINDS];
    expect([...grouped].sort()).toEqual([...serverKinds].sort());
  });

  it("keeps Wealth's kinds out of Spending's sections", () => {
    const spending = INSIGHT_GROUPS.flatMap((g) => [...g.kinds]) as string[];
    expect(WEALTH_INSIGHT_KINDS.filter((k) => spending.includes(k))).toEqual([]);
    expect(isWealthInsight({ kind: "balance_drift" })).toBe(true);
    expect(isWealthInsight({ kind: "annual_fee" })).toBe(false);
  });
});

describe("insightTarget: Wealth mode's kinds", () => {
  const ACC = "acc_01m5d2t402gjg9em2wfdbx98es";
  it("sends a stale balance or a drift to the account's page", () => {
    expect(insightTarget({ kind: "balance_stale", data: { account_code: ACC, as_of: null } })).toEqual({
      to: "/wealth/accounts/$accountCode", params: { accountCode: ACC }, search: {}, label: "Update the balance",
    });
    expect(insightTarget({ kind: "balance_drift", data: { account_code: ACC, checkpoint_code: "bcp_x" } })).toMatchObject({ to: "/wealth/accounts/$accountCode", label: "See the account" });
  });

  it("falls back to the accounts list without a valid account code", () => {
    expect(insightTarget({ kind: "balance_stale", data: { account_code: "nope" } })).toEqual({ to: "/wealth/accounts", label: "See accounts" });
  });

  it("sends a late salary to cash flow and an annual fee to the cards", () => {
    expect(insightTarget({ kind: "salary_late", data: { usual_day: 25 } })).toMatchObject({ to: "/wealth/cash-flow" });
    expect(insightTarget({ kind: "annual_fee", data: { account_code: ACC } })).toMatchObject({ to: "/cards" });
  });
});
