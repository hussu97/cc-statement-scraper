import { describe, expect, it } from "vitest";
import { ApiError } from "./api";
import { holdingErrorMessage, saveHoldingArgs } from "./holdings";

describe("holdingErrorMessage", () => {
  it("says who may change investments and what went wrong", () => {
    expect(holdingErrorMessage(new ApiError("x", { code: "42501" }))).toMatch(/owner/);
    expect(holdingErrorMessage(new ApiError("x", { code: "P0002" }))).toMatch(/isn't in this ledger/);
    expect(holdingErrorMessage({ code: "23514", message: "violates check" })).toMatch(/out of range/);
  });

  it("passes the server's readable 22023 message through, as a sentence", () => {
    expect(holdingErrorMessage(new ApiError("grams must be above 0", { code: "22023" }))).toBe("Grams must be above 0.");
    expect(holdingErrorMessage(new ApiError("", { code: "22023" }))).toMatch(/Check the holding/);
  });

  it("falls back to the error's own message, then a generic one", () => {
    expect(holdingErrorMessage(new Error("Network down"))).toBe("Network down");
    expect(holdingErrorMessage(null)).toMatch(/Couldn't save/);
  });
});

describe("saveHoldingArgs", () => {
  it("sends a metal's fields with kind metal and nothing of the other kinds", () => {
    const args = saveHoldingArgs("prf_1", { name: "Bar", metal: "gold", grams: "116.638", form: "bar", karat: 24, fineness: 9999, cost_aed: "52000" });
    expect(args).toEqual({ p_profile_code: "prf_1", p_name: "Bar", p_kind: "metal", p_metal: "gold", p_grams: "116.638", p_form: "bar", p_karat: 24, p_fineness: 9999, p_cost_aed: "52000" });
  });

  it("sends a plan's or deposit's fields and no metal fields", () => {
    expect(saveHoldingArgs("prf_1", { holding_code: "hld_1", kind: "plan", name: "RL360 plan", currency: "USD", institution: "RL360", link_pattern: "RI", link_exact: true })).toEqual({
      p_profile_code: "prf_1",
      p_name: "RL360 plan",
      p_holding_code: "hld_1",
      p_kind: "plan",
      p_currency: "USD",
      p_institution: "RL360",
      p_link_pattern: "RI",
      p_link_exact: true,
    });
    const dep = saveHoldingArgs("prf_1", { kind: "deposit", name: "FD", currency: "AED", principal: "100000", rate_pct: "4.25", acquired_on: "2026-06-23", maturity_on: "2027-06-23" });
    expect(dep).toMatchObject({ p_kind: "deposit", p_principal: "100000", p_rate_pct: "4.25", p_acquired_on: "2026-06-23", p_maturity_on: "2027-06-23" });
    expect(dep).not.toHaveProperty("p_metal");
    expect(dep).not.toHaveProperty("p_cost_aed");
  });
});

describe("holdingErrorMessage: flows and links", () => {
  it("names a removed flow and a missing transaction", () => {
    expect(holdingErrorMessage(new ApiError("flow not found (a metal's cost is edited on the holding)", { code: "P0002" }))).toMatch(/already removed/);
    expect(holdingErrorMessage(new ApiError("transaction not found", { code: "P0002" }))).toMatch(/transaction isn't in this ledger/);
    expect(holdingErrorMessage(new ApiError("the transaction has no AED amount yet", { code: "22023" }))).toBe("The transaction has no AED amount yet.");
    expect(holdingErrorMessage(new ApiError('new row violates check constraint "holdings_link_pattern_check"', { code: "23514" }))).toMatch(/at least 3 characters, or 2 with Match/);
  });
});
