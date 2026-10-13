import { describe, expect, it } from "vitest";
import { groupInsights, INSIGHT_GROUPS } from "./overview";

const i = (kind: string, severity: string, created_at: string) => ({ kind, severity, created_at, insight_code: `${kind}-${created_at}` });

describe("groupInsights (MA-5)", () => {
  it("sections insights by the screen that answers them, in a fixed order, alerts first", () => {
    const groups = groupInsights([
      i("review_backlog", "info", "2026-10-10"),
      i("budget_risk", "warn", "2026-10-09"),
      i("large_transaction", "info", "2026-10-12"),
      i("category_spike", "alert", "2026-10-01"),
      i("statement_due", "warn", "2026-10-11"),
      i("price_change", "info", "2026-10-02"),
      i("uncategorized", "warn", "2026-10-03"),
    ]);
    expect(groups.map((g) => [g.key, g.label, g.items.map((x) => x.kind)])).toEqual([
      ["spending", "Spending", ["category_spike", "large_transaction"]],
      ["budgets", "Budgets", ["budget_risk"]],
      ["subscriptions", "Subscriptions", ["price_change"]],
      ["statements", "Statements", ["statement_due"]],
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

  it("covers every kind the server's CHECK allows", () => {
    const serverKinds = ["spend_pace", "category_spike", "budget_risk", "price_change", "new_recurring", "statement_due", "uncategorized", "review_backlog", "large_transaction"];
    const grouped = INSIGHT_GROUPS.flatMap((g) => [...g.kinds]);
    expect([...grouped].sort()).toEqual([...serverKinds].sort());
  });
});
