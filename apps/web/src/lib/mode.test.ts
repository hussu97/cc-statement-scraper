// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { isAppMode, MODE_INFO, modeOfPath, readRememberedMode, rememberMode, resolveMode, visibleModes } from "./mode";

describe("modeOfPath", () => {
  it("files Wealth's screens under Wealth, the old cash flow address too", () => {
    for (const p of ["/wealth", "/wealth/accounts", "/wealth/accounts/acc_x", "/wealth/investments", "/wealth/cash-flow", "/cash-flow"]) expect(modeOfPath(p)).toBe("wealth");
  });

  it("files the spending screens under Spending", () => {
    for (const p of ["/", "/activity", "/insights", "/insights/category/none", "/budgets", "/cards", "/statements/stm_x"]) expect(modeOfPath(p)).toBe("spending");
  });

  it("files India's screens under India", () => {
    for (const p of ["/india", "/india/kite", "/india/coin"]) expect(modeOfPath(p)).toBe("india");
    expect(modeOfPath("/indiana")).toBe("spending");
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
    expect(modeOfPath(MODE_INFO.india.home)).toBe("india");
  });

  it("drops a remembered India once the ledger is known not to have it", () => {
    expect(resolveMode("/settings", "india", true)).toBe("india");
    expect(resolveMode("/settings", "india", undefined)).toBe("india");
    expect(resolveMode("/settings", "india", false)).toBe("spending");
    // The path still wins: a direct visit to /india shows India (and its empty state).
    expect(resolveMode("/india", "spending", false)).toBe("india");
  });
});

describe("visibleModes", () => {
  it("offers India only when the ledger has it, or while it is on screen", () => {
    expect(visibleModes(true, "spending")).toEqual(["spending", "wealth", "india"]);
    expect(visibleModes(false, "spending")).toEqual(["spending", "wealth"]);
    expect(visibleModes(undefined, "wealth")).toEqual(["spending", "wealth"]);
    expect(visibleModes(false, "india")).toEqual(["spending", "wealth", "india"]);
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
