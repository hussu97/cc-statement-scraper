import { describe, expect, it } from "vitest";
import { ApiError } from "./api";
import { holdingErrorMessage } from "./holdings";

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
