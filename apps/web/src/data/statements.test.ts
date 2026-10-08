import { describe, expect, it } from "vitest";
import { dueInDays, isStatementCode, lineAmount, lineTitle, utilisationOf, utilisationTone, type StatementLine } from "./statements";
import { displayAmount } from "@/lib/money";

const line = (over: Partial<StatementLine> = {}): StatementLine => ({
  line_code: "stl_1",
  txn_code: "txn_1",
  txn_date: "2026-09-02",
  posting_date: null,
  description: "DUNE COFFEE ROASTERS DUBAI",
  merchant_name: "Dune Coffee Roasters",
  amount_aed: "27.28",
  amount_original: "27.28",
  currency_original: "AED",
  category_code: null,
  kind: "purchase",
  card_last4: "4821",
  ...over,
});

describe("isStatementCode", () => {
  it("accepts stm_ + 26-char ULIDs only", () => {
    expect(isStatementCode("stm_01m4eap89ybfjbzfbcf4b9ek7a")).toBe(true);
    expect(isStatementCode("stm_short")).toBe(false);
    expect(isStatementCode("txn_01m4eap89ybfjbzfbcf4b9ek7a")).toBe(false);
    expect(isStatementCode(undefined)).toBe(false);
  });
});

describe("utilisationOf", () => {
  it("prefers the server's figure", () => {
    expect(utilisationOf({ utilisation: "0.4100", closing_balance: "100.00", credit_limit: "1000.00" })).toBe(0.41);
  });
  it("otherwise shows closing / limit for display only", () => {
    expect(utilisationOf({ closing_balance: "8285.56", credit_limit: "30000.00" })).toBeCloseTo(0.2762, 4);
  });
  it("is null without a limit, and never negative (a credit balance)", () => {
    expect(utilisationOf({ closing_balance: "100.00", credit_limit: null })).toBeNull();
    expect(utilisationOf({ closing_balance: "100.00", credit_limit: "0" })).toBeNull();
    expect(utilisationOf({ closing_balance: "-50.00", credit_limit: "1000.00" })).toBe(0);
  });
  it("tones like the statements list", () => {
    expect(utilisationTone(0.1)).toBe("positive");
    expect(utilisationTone(0.5)).toBe("warn");
    expect(utilisationTone(0.9)).toBe("danger");
    expect(utilisationTone(null)).toBe("positive");
  });
});

describe("lines", () => {
  it("titles a line by merchant, else by the printed description", () => {
    expect(lineTitle(line())).toBe("Dune Coffee Roasters");
    expect(lineTitle(line({ merchant_name: null }))).toBe("DUNE COFFEE ROASTERS DUBAI");
    expect(lineTitle(line({ merchant_name: "  " }))).toBe("DUNE COFFEE ROASTERS DUBAI");
  });

  it("shows AED with the foreign original underneath, never a foreign amount labelled AED", () => {
    const fx = lineAmount(line({ amount_aed: "92.58", amount_original: "25.00", currency_original: "USD" }), "debit");
    expect(fx.direction).toBe("debit");
    expect(displayAmount(fx)).toEqual({ value: "92.58", currency: "AED", awaitingFx: false, original: { value: "25.00", currency: "USD" } });
    const unpriced = lineAmount(line({ amount_aed: null, amount_original: "25.00", currency_original: "USD" }), "debit");
    expect(displayAmount(unpriced)).toMatchObject({ value: "25.00", currency: "USD", awaitingFx: true });
    expect(lineAmount(line(), "credit").direction).toBe("credit");
  });
});

describe("dueInDays", () => {
  it("counts calendar days to the due date", () => {
    expect(dueInDays("2026-10-13", "2026-10-08")).toBe(5);
    expect(dueInDays("2026-10-08", "2026-10-08")).toBe(0);
    expect(dueInDays("2026-10-01", "2026-10-08")).toBe(-7);
    expect(dueInDays(null, "2026-10-08")).toBeNull();
    expect(dueInDays("nope", "2026-10-08")).toBeNull();
  });
});
