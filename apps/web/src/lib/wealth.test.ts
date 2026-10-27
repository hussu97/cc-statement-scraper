import { describe, expect, it } from "vitest";
import {
  accountKindLabel,
  accountMonthParam,
  accountMonthStart,
  availableLedgerFilters,
  balancePoints,
  balanceRange,
  cardAnchorNote,
  debitTag,
  formatInOut,
  formatLedgerAmount,
  hasBalances,
  matchesLedgerFilter,
  netWorthHistoryMonths,
  netWorthNotes,
  netWorthPoints,
  accountTab,
  parseAccountSearch,
  shiftAccountMonth,
} from "./wealth";

const TODAY = "2026-10-20";

describe("account page month (?month=YYYY-MM)", () => {
  it("accepts a past or current month, and drops the rest as undefined", () => {
    expect(parseAccountSearch({ month: "2026-09" }, TODAY)).toEqual({ month: "2026-09", tab: undefined });
    expect(parseAccountSearch({ month: "2026-10" }, TODAY)).toEqual({ month: "2026-10", tab: undefined });
    // undefined, not absent: it must override the raw URL the root route passes through.
    expect(parseAccountSearch({ month: "2026-11" }, TODAY)).toHaveProperty("month", undefined);
    expect(parseAccountSearch({ month: "2026-13" }, TODAY)).toHaveProperty("month", undefined);
    expect(parseAccountSearch({ month: "2026-09-01" }, TODAY)).toHaveProperty("month", undefined);
    expect(parseAccountSearch({}, TODAY)).toHaveProperty("month", undefined);
  });

  it("keeps a known tab other than the default", () => {
    expect(parseAccountSearch({ tab: "past" }, TODAY)).toEqual({ month: undefined, tab: "past" });
    expect(parseAccountSearch({ tab: "transactions", month: "2026-09" }, TODAY)).toEqual({ month: "2026-09", tab: "transactions" });
    expect(parseAccountSearch({ tab: "portfolio" }, TODAY)).toHaveProperty("tab", undefined);
    expect(parseAccountSearch({ tab: "<x>" }, TODAY)).toHaveProperty("tab", undefined);
    expect(accountTab(undefined)).toBe("portfolio");
    expect(accountTab("past")).toBe("past");
  });

  it("turns the param into a first-of-month and back; this month is the default", () => {
    expect(accountMonthStart(undefined, TODAY)).toBe("2026-10-01");
    expect(accountMonthStart("2026-03", TODAY)).toBe("2026-03-01");
    expect(accountMonthParam("2026-03-01", TODAY)).toBe("2026-03");
    expect(accountMonthParam("2026-10-01", TODAY)).toBeUndefined();
    expect(shiftAccountMonth("2026-10-01", -1, TODAY)).toBe("2026-09");
    expect(shiftAccountMonth("2026-09-01", 1, TODAY)).toBeUndefined();
    expect(shiftAccountMonth("2026-01-01", -1, TODAY)).toBe("2025-12");
  });
});

describe("ledger amounts", () => {
  it("signs a row from the account's side, keeping its decimals", () => {
    expect(formatLedgerAmount("50000.00", "credit")).toBe("+AED 50,000.00");
    expect(formatLedgerAmount("1500.5", "debit")).toBe("−AED 1,500.50");
    expect(formatLedgerAmount("20", "debit", "USD")).toBe("−USD 20.00");
    expect(formatLedgerAmount(null, "debit")).toBe("—");
  });

  it("signs a period's money in and out as whole-unit totals", () => {
    expect(formatInOut("50000.00", "in")).toBe("+AED 50,000");
    expect(formatInOut("31100.40", "out")).toBe("−AED 31,100");
    expect(formatInOut("0", "out")).toBe("AED 0");
  });
});

describe("ledger display filter", () => {
  const rows = [{ flow: "income" }, { flow: "support" }, { flow: "internal_out" }, { flow: null }];

  it("matches by flow; All matches everything, a row with no flow only All", () => {
    expect(matchesLedgerFilter("income", "in")).toBe(true);
    expect(matchesLedgerFilter("money_in", "unfiled")).toBe(true);
    expect(matchesLedgerFilter("money_in", "in")).toBe(true);
    expect(matchesLedgerFilter("spend", "committed")).toBe(false);
    expect(matchesLedgerFilter(null, "moves")).toBe(false);
    expect(matchesLedgerFilter(null, "all")).toBe(true);
  });

  it("offers All plus each filter that has a row", () => {
    expect(availableLedgerFilters(rows).map((f) => f.value)).toEqual(["all", "in", "committed", "moves"]);
    expect(availableLedgerFilters([]).map((f) => f.value)).toEqual(["all"]);
  });
});

describe("labels and tags", () => {
  it("names account kinds and tags debit purchases", () => {
    expect(accountKindLabel("current")).toBe("Current account");
    expect(accountKindLabel("savings")).toBe("Savings account");
    expect(debitTag("current")).toBe("Debit");
    expect(debitTag("savings")).toBe("Debit");
    expect(debitTag("credit_card")).toBeNull();
    expect(debitTag(null)).toBeNull();
  });

  it("says where a card's owed figure comes from", () => {
    expect(cardAnchorNote("statement")).toMatch(/statement/);
    expect(cardAnchorNote("none")).toBe("No balance from the bank yet");
  });
});

describe("balance chart points", () => {
  it("keeps a null balance as a gap, never a zero", () => {
    const pts = balancePoints([
      { date: "2026-10-01", balance: null },
      { date: "2026-10-02", balance: "1200.50" },
      { date: "2026-10-03", balance: "-40" },
    ]);
    expect(pts).toEqual([
      { date: "2026-10-01", balance: null },
      { date: "2026-10-02", balance: 1200.5 },
      { date: "2026-10-03", balance: -40 },
    ]);
    expect(hasBalances(pts)).toBe(true);
    expect(hasBalances(pts.slice(0, 1))).toBe(false);
  });

  it("spans the last 90 days, today included (the server allows 400)", () => {
    expect(balanceRange(TODAY)).toEqual({ from: "2026-07-23", to: TODAY });
  });
});

describe("net worth", () => {
  const base = { cash_complete: true, cash_missing_count: 0, cash_stale_count: 0, owed_complete: true, owed_has_estimate: false, has_bank_accounts: true, holdings_complete: true, holdings_count: 0 };

  it("says nothing when every figure is known", () => {
    expect(netWorthNotes(base)).toEqual([]);
  });

  it("names missing and old balances, and estimates, honestly", () => {
    expect(netWorthNotes({ ...base, cash_complete: false, cash_missing_count: 1, cash_stale_count: 1, owed_has_estimate: true })).toEqual([
      "1 account has no balance",
      "1 is over a week old",
      "card balance includes an estimate",
    ]);
    expect(netWorthNotes({ ...base, cash_complete: false, cash_stale_count: 2 })).toEqual(["2 balances are over a week old"]);
    expect(netWorthNotes({ ...base, cash_complete: false })).toEqual(["Some bank amounts have no AED value yet"]);
    expect(netWorthNotes({ ...base, owed_complete: false })).toEqual(["A card has no balance yet"]);
  });

  it("says when a gold or silver price is missing or stale", () => {
    expect(netWorthNotes({ ...base, holdings_complete: false, holdings_count: 2 })).toEqual(["A gold or silver price is missing or over 3 days old"]);
  });

  it("says when there is no bank account to count", () => {
    expect(netWorthNotes({ ...base, has_bank_accounts: false })[0]).toBe("No bank accounts yet: this is only what the cards owe");
    expect(netWorthNotes({ ...base, has_bank_accounts: false, holdings_count: 1 })[0]).toBe("No bank accounts yet: cash isn't counted");
  });

  it("charts the series and counts the months before today's live point", () => {
    const pts = netWorthPoints([
      { month: "2026-09-01", as_of: "2026-09-30", net_aed: "1000.00", cash_aed: "3000", owed_aed: "2000", complete: true, is_live: false },
      { month: "2026-10-01", as_of: "2026-10-20", net_aed: "-50.25", cash_aed: "0", holdings_aed: "1200.50", owed_aed: "1250.75", complete: false, is_live: true },
    ]);
    expect(pts[0]?.holdings).toBeNull();
    expect(pts[1]).toEqual({ month: "2026-10-01", as_of: "2026-10-20", net: -50.25, cash: 0, holdings: 1200.5, owed: 1250.75, complete: false, is_live: true });
    expect(netWorthHistoryMonths(pts)).toBe(1);
    expect(netWorthHistoryMonths(pts.slice(1))).toBe(0);
  });
});
