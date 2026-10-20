import { describe, expect, it } from "vitest";
import { ApiError, toApiError } from "./api";
import { balanceErrorMessage, bankAccountErrorMessage } from "./cash";
import { keys, LEDGER_DOMAINS } from "./keys";

describe("cash keys", () => {
  it("live under the profile's cash domain, which ledger changes refresh", () => {
    expect(keys.cashPosition("P")).toEqual(["p", "P", "cash", "position"]);
    expect(keys.cashFlow("P", "2026-05-01", "2026-10-31")).toEqual(["p", "P", "cash", "flow", "2026-05-01", "2026-10-31", "all"]);
    expect(keys.cashFlow("P", "2026-05-01", "2026-10-31", "acc_1")).toEqual(["p", "P", "cash", "flow", "2026-05-01", "2026-10-31", "acc_1"]);
    // Wealth mode's reads refresh with the same domain: a balance or a category change.
    for (const k of [keys.netWorth("P"), keys.netWorthSeries("P", 12), keys.accountLedger("P", "acc_1", "a", "b"), keys.balanceSeries("P", "acc_1", "a", "b")]) {
      expect(k.slice(0, 3)).toEqual(["p", "P", "cash"]);
    }
    expect(LEDGER_DOMAINS).toContain("cash");
  });
});

describe("bank account errors", () => {
  // The server's own messages, as create_bank_account raises them.
  const err = (code: string, message: string) => toApiError({ code, message });

  it("maps create_bank_account's codes to plain words", () => {
    expect(bankAccountErrorMessage(err("23505", "this ledger already has a ADCB account ending 810001"))).toMatch(/already has an account/);
    expect(bankAccountErrorMessage(err("22023", "account_ref is the 3–12 digits"))).toMatch(/3–12 digits/);
    expect(bankAccountErrorMessage(err("P0002", "unknown bank XYZ"))).toMatch(/bank isn't available/);
    expect(bankAccountErrorMessage(err("42501", "not an owner"))).toMatch(/owner/);
    expect(bankAccountErrorMessage(new ApiError("Network down"))).toBe("Network down");
    expect(bankAccountErrorMessage(null)).toMatch(/Couldn't add/);
  });

  it("maps record_balance's codes, telling a future date from a bad number", () => {
    expect(balanceErrorMessage(err("22023", "a balance can't be dated in the future"))).toBe("A balance can't be dated in the future.");
    expect(balanceErrorMessage(err("22023", "balance must be a number with at most two decimals"))).toMatch(/at most two decimals/);
    expect(balanceErrorMessage(err("P0002", "unknown bank account acc_x"))).toMatch(/isn't a bank account/);
    expect(balanceErrorMessage(err("42501", "x"))).toMatch(/owner/);
    expect(balanceErrorMessage(undefined)).toMatch(/Couldn't save/);
  });
});
