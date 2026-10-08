// Pure logic behind the 04-web audit fixes (WEB-01 … WEB-08, WEB-18, WEB-25).
import { describe, expect, it, vi } from "vitest";
import { fetchPage, isRangeNotSatisfiable } from "@/data/api";
import { clampPage } from "@/lib/pagination";
import { displayAmount, formatBadgeCount } from "@/lib/money";
import { syncSearchText } from "@/lib/activity-filters";
import { reviewFooterActions, reviewQueriesEnabled } from "@/data/reviews";
import { insightTarget } from "@/data/overview";
import { mergeMerchants } from "@/data/rules";
import { emailCodeOptions, NO_ACCOUNT_MESSAGE, signInErrorMessage } from "@/data/auth";
import { axisTickInterval } from "@/components/insights/labels";

describe("WEB-01: out-of-range pages", () => {
  it("clamps a page past the end to the last page, and an empty result to page 1", () => {
    expect(clampPage(99, 498, 100)).toBe(5);
    expect(clampPage(5, 498, 100)).toBeNull();
    expect(clampPage(1, 0, 100)).toBeNull();
    expect(clampPage(3, 0, 100)).toBe(1);
    expect(clampPage(2, 100, 100)).toBe(1);
  });

  it("recognises PostgREST's range error", () => {
    expect(isRangeNotSatisfiable({ code: "PGRST103" })).toBe(true);
    expect(isRangeNotSatisfiable(null, 416)).toBe(true);
    expect(isRangeNotSatisfiable({ code: "42501" }, 403)).toBe(false);
  });

  it("turns a 416 into an empty page with the real total instead of an error", async () => {
    const countOnly = vi.fn(async () => ({ data: null, error: null, count: 498, status: 200 }));
    const page = await fetchPage(
      async () => ({ data: null, error: { message: "Requested range not satisfiable", code: "PGRST103" }, count: null, status: 416 }),
      countOnly,
    );
    expect(page).toEqual({ rows: [], total: 498 });
    expect(countOnly).toHaveBeenCalledOnce();
  });

  it("returns rows and the exact count, and still throws real errors", async () => {
    const countOnly = vi.fn();
    await expect(fetchPage(async () => ({ data: [{ a: 1 }], error: null, count: 7, status: 200 }), countOnly)).resolves.toEqual({ rows: [{ a: 1 }], total: 7 });
    expect(countOnly).not.toHaveBeenCalled();
    await expect(fetchPage(async () => ({ data: null, error: { message: "boom", code: "XX000" }, status: 500 }), countOnly)).rejects.toThrow("boom");
  });
});

describe("match_reviews before session restore", () => {
  it("only queries reviews with a session and a profile (anon has no grant)", () => {
    expect(reviewQueriesEnabled(null, "prf_x")).toBe(false);
    expect(reviewQueriesEnabled({ access_token: "t" }, "")).toBe(false);
    expect(reviewQueriesEnabled({ access_token: "t" }, null)).toBe(false);
    expect(reviewQueriesEnabled({ access_token: "t" }, "prf_x")).toBe(true);
  });

  it("formats the nav badge count", () => {
    expect(formatBadgeCount(3)).toBe("3");
    expect(formatBadgeCount(1200)).toBe("99+");
  });
});

describe("WEB-04: the email code never signs anyone up", () => {
  it("passes shouldCreateUser: false and no redirect link", () => {
    expect(emailCodeOptions()).toEqual({ shouldCreateUser: false });
  });

  it("explains an unknown email instead of GoTrue's wording", () => {
    expect(signInErrorMessage({ message: "Signups not allowed for otp", code: "otp_disabled" })).toBe(NO_ACCOUNT_MESSAGE);
    expect(signInErrorMessage(new Error("Signups not allowed for otp"))).toBe(NO_ACCOUNT_MESSAGE);
    expect(signInErrorMessage(new Error("Something else"))).toBe("Something else");
  });
});

describe("WEB-05: foreign amounts without an AED estimate", () => {
  it("shows the original currency and flags awaiting FX, never AED", () => {
    expect(displayAmount({ amount_aed: null, amount_original: 1000, currency_original: "INR" })).toEqual({
      value: 1000,
      currency: "INR",
      awaitingFx: true,
      original: null,
    });
  });

  it("shows AED with the original underneath once estimated", () => {
    expect(displayAmount({ amount_aed: "44.10", amount_original: 1000, currency_original: "inr" })).toEqual({
      value: "44.10",
      currency: "AED",
      awaitingFx: false,
      original: { value: 1000, currency: "INR" },
    });
  });

  it("treats AED and a missing currency as AED", () => {
    expect(displayAmount({ amount_aed: null, amount_original: 50, currency_original: "AED" })).toMatchObject({ currency: "AED", awaitingFx: false });
    expect(displayAmount({ amount_aed: 50, amount_original: 50, currency_original: null })).toMatchObject({ currency: "AED", original: null });
  });
});

describe("WEB-07: every review can be cleared", () => {
  const r = (reason: string, subject_type = "sms") => ({ reason, subject_type });
  it("offers retry-with-AI, not-a-transaction and dismiss for an unparsed SMS without a proposed format", () => {
    expect(reviewFooterActions(r("unparsed_sms"), false)).toEqual(["retry_ai", "not_a_transaction", "dismiss"]);
    expect(reviewFooterActions(r("unparsed_sms"), true)).toEqual([]);
  });

  it("keeps the existing actions for other reasons", () => {
    expect(reviewFooterActions(r("ambiguous", "statement_line"), false)).toEqual(["separate", "dismiss"]);
    expect(reviewFooterActions(r("unknown_card"), false)).toEqual(["not_a_transaction", "dismiss"]);
    expect(reviewFooterActions(r("period_overlap", "statement"), false)).toEqual(["supersede", "dismiss"]);
    expect(reviewFooterActions(r("orphaned", "transaction"), false)).toEqual(["dismiss"]);
  });
});

describe("WEB-08: search box follows ?q=", () => {
  it("syncs when the URL changed for another reason", () => {
    expect(syncSearchText(undefined, "cafe")).toBe("");
    expect(syncSearchText("tea", "cafe")).toBe("tea");
  });
  it("leaves the box alone when the URL holds what it wrote", () => {
    expect(syncSearchText("cafe", "cafe")).toBeNull();
    expect(syncSearchText(undefined, undefined)).toBeNull();
  });
});

describe("WEB-18: Trends axis labels", () => {
  it("shows every label when they fit, else every Nth", () => {
    expect(axisTickInterval(6, 7)).toBe(0);
    expect(axisTickInterval(12, 7)).toBe(1);
    expect(axisTickInterval(26, 7)).toBe(3);
    expect(axisTickInterval(12, 14)).toBe(0);
  });
});

describe("WEB-25: insight cards link to their screen", () => {
  const txn = "txn_0123456789abcdefghijklmnop";
  const cat = "cat_0123456789abcdefghijklmnop";
  it("maps each kind", () => {
    expect(insightTarget({ kind: "budget_risk", data: {} })).toMatchObject({ to: "/budgets" });
    expect(insightTarget({ kind: "statement_due", data: {} })).toMatchObject({ to: "/cards", search: { tab: "statements" } });
    expect(insightTarget({ kind: "price_change", data: {} })).toMatchObject({ to: "/insights", search: { tab: "subscriptions" } });
    expect(insightTarget({ kind: "uncategorized", data: {} })).toMatchObject({ to: "/activity", search: { category: "none" } });
    expect(insightTarget({ kind: "category_spike", data: { category_code: cat } })).toMatchObject({ to: "/activity", search: { category: cat } });
    expect(insightTarget({ kind: "category_spike", data: {} })).toMatchObject({ to: "/insights", search: { tab: "categories" } });
    expect(insightTarget({ kind: "large_transaction", data: { txn_code: txn } })).toMatchObject({ to: "/activity", search: { txn } });
    expect(insightTarget({ kind: "review_backlog", data: null })).toMatchObject({ to: "/review" });
  });
  it("ignores unknown kinds and non-code data", () => {
    expect(insightTarget({ kind: "something_new", data: {} })).toBeNull();
    expect(insightTarget({ kind: "large_transaction", data: { txn_code: "javascript:alert(1)" } })).toMatchObject({ search: {} });
  });
});

describe("WEB-02: merchants beyond the leaderboard cap", () => {
  const a = (merchant_code: string, name: string | null, source = "manual") =>
    ({
      profile_code: "prf_x",
      merchant_code,
      category_code: "cat_a",
      source,
      confidence: null,
      model: null,
      category_set_hash: null,
      created_at: "",
      updated_at: "",
      merchants: name ? { display_name: name } : null,
    }) as Parameters<typeof mergeMerchants>[1][number];
  it("keeps leaderboard order and appends assigned merchants outside it", () => {
    const rows = mergeMerchants(
      [
        { merchant_code: "mer_1", merchant_name: "Carrefour", category_code: "cat_g", category_name: "Grocery", amount: 900, txn_count: 9, last_date: "2026-10-01" },
        { merchant_code: null, merchant_name: "(none)", category_code: null, category_name: null, amount: 5, txn_count: 1, last_date: "2026-10-01" },
      ],
      [a("mer_1", "Carrefour"), a("mer_9", "Zara", "llm"), a("mer_5", "Apple")],
    );
    expect(rows.map((r) => r.merchant_name)).toEqual(["Carrefour", "Apple", "Zara"]);
    expect(rows[0]!.assignment?.merchant_code).toBe("mer_1");
    expect(rows[0]!.assignment).not.toHaveProperty("merchants");
    expect(rows[2]).toMatchObject({ amount: null, txn_count: null, last_date: null });
  });
});
