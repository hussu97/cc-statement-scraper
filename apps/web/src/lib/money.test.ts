import { describe, expect, it } from "vitest";
import { displayRatio, formatChange, formatMoney, formatPercent, formatTxnAmount, moneyParts, toAmount } from "./money";

describe("money", () => {
  it("parses numbers and decimal strings", () => {
    expect(toAmount("1234.50")).toBe(1234.5);
    expect(toAmount("1,234.50")).toBe(1234.5);
    expect(toAmount(12)).toBe(12);
    expect(toAmount("")).toBeNull();
    expect(toAmount(null)).toBeNull();
    expect(toAmount("abc")).toBeNull();
  });

  it("formats AED by default with two decimals", () => {
    expect(formatMoney("1234.5")).toBe("AED 1,234.50");
    expect(formatMoney(0)).toBe("AED 0.00");
    expect(formatMoney(null)).toBe("—");
    expect(formatMoney(undefined, { empty: "n/a" })).toBe("n/a");
  });

  it("uses a true minus and optional plus", () => {
    expect(formatMoney("-20")).toBe("−AED 20.00");
    expect(formatMoney(20, { signed: true })).toBe("+AED 20.00");
  });

  it("supports other currencies, bare and whole", () => {
    expect(formatMoney("10", { currency: "usd" })).toBe("USD 10.00");
    expect(formatMoney("1234.56", { bare: true })).toBe("1,234.56");
    expect(formatMoney("1234.56", { whole: true })).toBe("AED 1,235");
    expect(formatMoney("12500", { compact: true })).toBe("AED 12.5K");
  });

  it("shows credits with + and debits plain", () => {
    expect(formatTxnAmount("50", "credit")).toBe("+AED 50.00");
    expect(formatTxnAmount("50", "debit")).toBe("AED 50.00");
  });

  it("splits hero parts", () => {
    expect(moneyParts("836.6")).toEqual({ currency: "AED", figure: "836.60", negative: false });
  });

  it("display ratios and deltas", () => {
    expect(displayRatio("25", "100")).toBe(0.25);
    expect(displayRatio("25", 0)).toBeNull();
    expect(formatPercent(0.256)).toBe("26%");
    expect(formatChange("0.2000")).toBe("+20%");
    expect(formatChange("-0.2000")).toBe("−20%");
    expect(formatChange("0.0040")).toBe("±0%");
    expect(formatChange(-1)).toBe("−100%");
    expect(formatChange(null)).toBeNull();
    expect(formatChange("")).toBeNull();
  });
});
