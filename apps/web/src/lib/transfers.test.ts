import { describe, expect, it } from "vitest";
import { transferPeer } from "./transfers";

const row = { direction: "debit", transfer_txn_code: "txn_x", transfer_bank_code: "EIB", transfer_card_last4: "9216" };

describe("transferPeer", () => {
  it("names the card a debit paid", () => {
    expect(transferPeer(row)).toEqual({ prefix: "Paid to", txnCode: "txn_x", bankCode: "EIB", last4: "9216" });
  });
  it("names the card a credit came from", () => {
    expect(transferPeer({ ...row, direction: "credit", transfer_bank_code: "WIO", transfer_card_last4: "9202" })?.prefix).toBe("From");
  });
  it("is null for a row that is not a transfer", () => {
    expect(transferPeer({ ...row, transfer_txn_code: null })).toBeNull();
  });
});
