// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { isAppMode, MODE_INFO, modeOfPath, readRememberedMode, rememberMode, resolveMode } from "./mode";

describe("modeOfPath", () => {
  it("files Wealth's screens under Wealth, the old cash flow address too", () => {
    for (const p of ["/wealth", "/wealth/accounts", "/wealth/accounts/acc_x", "/wealth/investments", "/wealth/cash-flow", "/cash-flow"]) expect(modeOfPath(p)).toBe("wealth");
  });

  it("files the spending screens under Spending", () => {
    for (const p of ["/", "/activity", "/insights", "/insights/category/none", "/budgets", "/cards", "/statements/stm_x"]) expect(modeOfPath(p)).toBe("spending");
  });

  it("leaves the shared screens to the last mode", () => {
    for (const p of ["/review", "/rules", "/settings"]) expect(modeOfPath(p)).toBeNull();
  });

  it("matches whole segments only", () => {
    expect(modeOfPath("/wealthy")).toBe("spending");
    expect(modeOfPath("/reviews")).toBe("spending");
  });
});

describe("resolveMode", () => {
  it("prefers the path, then the remembered mode, then Spending", () => {
    expect(resolveMode("/wealth", "spending")).toBe("wealth");
    expect(resolveMode("/activity", "wealth")).toBe("spending");
    expect(resolveMode("/settings", "wealth")).toBe("wealth");
    expect(resolveMode("/settings", null)).toBe("spending");
    expect(resolveMode("/review", "junk")).toBe("spending");
  });

  it("each mode's home is a screen of that mode", () => {
    expect(modeOfPath(MODE_INFO.spending.home)).toBe("spending");
    expect(modeOfPath(MODE_INFO.wealth.home)).toBe("wealth");
  });
});

describe("remembered mode", () => {
  afterEach(() => window.localStorage.clear());

  it("round-trips through localStorage and ignores junk", () => {
    expect(readRememberedMode()).toBeNull();
    rememberMode("wealth");
    expect(readRememberedMode()).toBe("wealth");
    window.localStorage.setItem("ledger.mode", "investing");
    expect(readRememberedMode()).toBeNull();
    expect(isAppMode("spending")).toBe(true);
    expect(isAppMode(1)).toBe(false);
  });
});
