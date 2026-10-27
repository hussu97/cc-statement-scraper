import { describe, expect, it } from "vitest";
import {
  FLOW_GROUPS,
  FLOWS,
  balanceAsOf,
  balanceSourceLabel,
  bankAccountLabel,
  cashCaveat,
  cashFlowRange,
  flowChip,
  formatFlow,
  formatNet,
  monthFlows,
  netByMonth,
  netTone,
  normalizeAccountRef,
  normalizeBalance,
  parseCashFlowSearch,
  validateBankAccount,
  type CashFlowRow,
} from "./cash-flow";
import { accountLabel } from "@/data/overview";

const row = (month: string, flow: string, amount: string | number, n = 1): CashFlowRow => ({ month, flow, amount_aed: amount, txn_count: n });

// The demo ledger's October: salary 50,000, support 23,700, saving 7,400, an unfiled 1,500 out.
const OCT = [
  row("2026-10-01", "income", 50000),
  row("2026-10-01", "support", 23700),
  row("2026-10-01", "saving", 7400),
  row("2026-10-01", "money_out", 1500),
  row("2026-10-01", "spend", "812.40", 9),
  row("2026-10-01", "card_repayment", 3000),
  row("2026-10-01", "internal_out", 2000),
  row("2026-10-01", "net", "16587.60", 15),
  row("2026-09-01", "spend", 400, 3),
  row("2026-09-01", "net", -400, 3),
];

describe("flow groups", () => {
  it("files every flow in exactly one group", () => {
    const filed = FLOW_GROUPS.flatMap((g) => g.flows);
    expect([...filed].sort()).toEqual([...FLOWS].sort());
    expect(new Set(filed).size).toBe(filed.length);
  });

  it("groups a month's rows in display order, leaving out empty groups", () => {
    const m = monthFlows(OCT, "2026-10-01");
    expect(m.groups.map((g) => g.key)).toEqual(["in", "committed", "spent", "unfiled_out", "moves"]);
    expect(m.groups[0]!.lines.map((l) => l.flow)).toEqual(["income"]);
    expect(m.groups[1]!.lines.map((l) => [l.flow, l.amount])).toEqual([["support", 23700], ["saving", 7400]]);
    expect(m.net).toBe("16587.60");
    expect(m.hasMovements).toBe(true);
  });

  it("marks moves muted with their note, and unfiled flows as links", () => {
    const m = monthFlows(OCT, "2026-10-01");
    const moves = m.groups.find((g) => g.key === "moves")!;
    expect(moves.muted).toBe(true);
    expect(moves.note).toBe("Doesn't change net");
    expect(moves.lines.map((l) => l.flow)).toEqual(["card_repayment", "internal_out"]);
    expect(m.groups.find((g) => g.key === "unfiled_out")!.lines[0]!.unfiled).toBe(true);
    expect(m.groups[0]!.lines[0]!.unfiled).toBe(false);
  });

  it("an empty month has no groups and no net; an unknown flow is ignored", () => {
    const m = monthFlows([...OCT, row("2026-08-01", "something_new", 5)], "2026-08-01");
    expect(m).toEqual({ groups: [], net: null, hasMovements: false, partial: false });
  });

  it("accepts a timestamp-shaped month", () => {
    expect(monthFlows([row("2026-10-01T00:00:00", "income", 1)], "2026-10-01").hasMovements).toBe(true);
  });
});

describe("partial months (is_partial)", () => {
  it("marks a month before the first bank evidence, in the month's flows and the net table", () => {
    const rows = [
      { ...row("2026-08-01", "spend", 400, 3), is_partial: true },
      { ...row("2026-08-01", "net", -400, 3), is_partial: true },
      ...OCT,
    ];
    expect(monthFlows(rows, "2026-08-01").partial).toBe(true);
    expect(monthFlows(rows, "2026-10-01").partial).toBe(false);
    const nets = netByMonth(rows, "2026-10-01");
    expect(nets.find((n) => n.month === "2026-08-01")).toMatchObject({ net: -400, partial: true });
    expect(nets.find((n) => n.month === "2026-10-01")).toMatchObject({ partial: false });
  });
});

describe("flow chips", () => {
  it("names every flow for a ledger row; no chip for none or an unknown flow", () => {
    for (const f of FLOWS) expect(flowChip(f)?.label).toBeTruthy();
    expect(flowChip("income")).toEqual({ label: "Income", tone: "positive" });
    expect(flowChip("money_out")).toEqual({ label: "Money out (unfiled)", tone: "warn" });
    expect(flowChip("internal_in")?.label).toBe("From your account");
    expect(flowChip(null)).toBeNull();
    expect(flowChip("net")).toBeNull();
  });
});

describe("formatting", () => {
  it("signs money in and out", () => {
    expect(formatFlow(50000, "in")).toBe("+AED 50,000");
    expect(formatFlow("23700.00", "out")).toBe("−AED 23,700");
    // Refunds above spend: a negative out reads as money in.
    expect(formatFlow(-120, "out")).toBe("+AED 120");
    expect(formatFlow(null, "out")).toBe("—");
  });

  it("formats and tones the net", () => {
    expect(formatNet("16587.60")).toBe("+AED 16,588");
    expect(formatNet(-400)).toBe("−AED 400");
    expect(formatNet(null)).toBe("—");
    expect(netTone(1)).toBe("positive");
    expect(netTone("-1")).toBe("danger");
    expect(netTone(0)).toBe("neutral");
    expect(netTone(null)).toBe("neutral");
  });
});

describe("months", () => {
  it("fetches the six months up to the selected one", () => {
    expect(cashFlowRange("2026-10-01")).toEqual({ from: "2026-05-01", to: "2026-10-31" });
    expect(cashFlowRange("2026-02-01")).toEqual({ from: "2025-09-01", to: "2026-02-28" });
  });

  it("lists six months of net, newest first, null where nothing moved", () => {
    const rows = netByMonth(OCT, "2026-10-01");
    expect(rows.map((r) => r.month)).toEqual(["2026-10-01", "2026-09-01", "2026-08-01", "2026-07-01", "2026-06-01", "2026-05-01"]);
    expect(rows.map((r) => r.net)).toEqual(["16587.60", -400, null, null, null, null]);
    expect(rows[0]!.label).toMatch(/Oct/);
  });

  it("parses ?month= to a past or current first-of-month", () => {
    const today = "2026-10-20";
    expect(parseCashFlowSearch({ month: "2026-09-01" }, today)).toEqual({ month: "2026-09-01" });
    expect(parseCashFlowSearch({ month: "2026-10-01" }, today)).toEqual({ month: "2026-10-01" });
    expect(parseCashFlowSearch({ month: "2026-11-01" }, today)).toEqual({ month: undefined });
    expect(parseCashFlowSearch({ month: "2026-09-15" }, today)).toEqual({ month: undefined });
    expect(parseCashFlowSearch({ month: "2026-13-01" }, today)).toEqual({ month: undefined });
    expect(parseCashFlowSearch({ month: 5 }, today)).toEqual({ month: undefined });
    expect(parseCashFlowSearch({}, today)).toEqual({ month: undefined });
  });

  it("reads ?account= as a bank account code, and returns dropped keys as undefined", () => {
    const today = "2026-10-20";
    const acc = "acc_01m5d2t402gjg9em2wfdbx98es";
    expect(parseCashFlowSearch({ month: "2026-09-01", account: acc }, today)).toEqual({ month: "2026-09-01", account: acc });
    const bad = parseCashFlowSearch({ account: "acc_nope" }, today);
    expect(bad).toHaveProperty("account", undefined);
    expect(bad).toHaveProperty("month", undefined);
  });
});

describe("bank accounts", () => {
  it("names an account by nickname, else kind and digits", () => {
    expect(bankAccountLabel({ kind: "current", nickname: " Salary ", account_ref: "810001" })).toBe("Salary");
    expect(bankAccountLabel({ kind: "current", nickname: null, account_ref: "810001" })).toBe("Current ··· 810001");
    expect(bankAccountLabel({ kind: "savings", nickname: "", account_ref: null })).toBe("Savings account");
  });

  it("accountLabel names a bank account in filters, and a card as before", () => {
    expect(accountLabel({ bank_code: "ADCB", nickname: null, product_name: null, kind: "current", account_ref: "810001" })).toBe("ADCB · Current ··· 810001");
    expect(accountLabel({ bank_code: "FAB", nickname: null, product_name: "Cashback", kind: "credit_card" })).toBe("FAB · Cashback");
    expect(accountLabel({ bank_code: "FAB", nickname: null, product_name: "Cashback" })).toBe("FAB · Cashback");
  });

  it("labels the balance source", () => {
    expect(balanceSourceLabel("sms")).toBe("from SMS");
    expect(balanceSourceLabel("manual")).toBe("entered");
    expect(balanceSourceLabel("statement")).toBe("from statement");
    expect(balanceSourceLabel("broker")).toBe("from broker sync");
    expect(balanceSourceLabel(null)).toBeNull();
    // A source this build doesn't know yet says nothing rather than breaking the page.
    expect(balanceSourceLabel("something_new")).toBeNull();
  });

  it("explains an incomplete total", () => {
    expect(cashCaveat({ complete: true, stale_count: 0, missing_count: 0 })).toBeNull();
    expect(cashCaveat({ complete: false, stale_count: 0, missing_count: 1 })).toBe("1 account has no balance yet");
    expect(cashCaveat({ complete: true, stale_count: 2, missing_count: 0 })).toBe("2 balances are over a week old");
    expect(cashCaveat({ complete: false, stale_count: 1, missing_count: 2 })).toBe("2 accounts have no balance yet; 1 balance is over a week old");
    expect(cashCaveat({ complete: false, stale_count: 0, missing_count: 0 })).toBe("Some amounts have no AED value yet");
  });

  it("validates the account digits", () => {
    expect(normalizeAccountRef("XXX 810-001")).toBe("810001");
    expect(validateBankAccount({ bank_code: "", account_ref: "810001" })).toMatch(/bank/);
    expect(validateBankAccount({ bank_code: "ADCB", account_ref: "810001" })).toBeNull();
    expect(validateBankAccount({ bank_code: "ADCB", account_ref: "" })).toBeNull();
    expect(validateBankAccount({ bank_code: "ADCB", account_ref: "12" })).toMatch(/3–12 digits/);
    expect(validateBankAccount({ bank_code: "ADCB", account_ref: "81a001" })).toMatch(/3–12 digits/);
  });

  it("normalises a typed balance to record_balance's decimal string", () => {
    expect(normalizeBalance("12,500.50")).toBe("12500.50");
    expect(normalizeBalance(" −40.25 ")).toBe("-40.25");
    expect(normalizeBalance("AED 300")).toBe("300");
    expect(normalizeBalance("1.234")).toBeNull();
    expect(normalizeBalance("abc")).toBeNull();
    expect(normalizeBalance("")).toBeNull();
  });

  it("dates a balance: now for today, the end of an earlier Dubai day, never the future", () => {
    const today = "2026-10-20";
    expect(balanceAsOf("", today)).toBeNull();
    expect(balanceAsOf("2026-10-20", today)).toBeNull();
    expect(balanceAsOf("2026-10-18", today)).toBe("2026-10-18T23:59:59+04:00");
    expect(balanceAsOf("2026-10-21", today)).toBeUndefined();
    expect(balanceAsOf("2026-02-30", today)).toBeUndefined();
  });
});
