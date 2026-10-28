import { describe, expect, it } from "vitest";
import { brokerRowFigures, brokerHoldingCodes, liveNotesOutsideBrokers, outsideBrokers, parseBrokerAccounts } from "./broker-accounts";

// Invented round numbers, shaped like broker_accounts_summary.
const RAW = [
  {
    account_code: "acc_00000000000000000000000001",
    provider: "swissquote",
    bank_code: "SWQ",
    name: "Swissquote",
    currency: "USD",
    cash: "1000.00",
    positions_value: "99000.00",
    total: "100000.00",
    total_aed: "367250.00",
    net_deposits: "90000.00",
    profit: "10000.00",
    profit_aed: "36725.00",
    change_24h: "-327.50",
    change_24h_aed: "-1202.74",
    change_24h_pct: "-0.55",
    live_notes: "5",
    positions: "9",
    last_synced_at: "2026-10-27T10:00:00Z",
    sync_status: "ok",
    holding_codes: ["hld_a", "hld_b", 3],
  },
  "junk",
  { name: "no code" },
];

describe("parseBrokerAccounts", () => {
  it("keeps accounts and drops anything else", () => {
    const a = parseBrokerAccounts(RAW);
    expect(a).toHaveLength(1);
    expect(a[0]).toMatchObject({ account_code: "acc_00000000000000000000000001", total: "100000.00", live_notes: "5", holding_codes: ["hld_a", "hld_b"] });
    expect(a[0]).toMatchObject({ profit_aed: "36725.00", change_24h: "-327.50", change_24h_aed: "-1202.74", change_24h_pct: "-0.55" });
    expect(parseBrokerAccounts(null)).toEqual([]);
  });
  it("reads the AED profit and the 24-hour change as null from an older server", () => {
    expect(parseBrokerAccounts([{ account_code: "acc_x", provider: "zerodha" }])[0]).toMatchObject({ profit_aed: null, change_24h: null, change_24h_aed: null, change_24h_pct: null });
  });
  it("defaults a missing name and currency", () => {
    expect(parseBrokerAccounts([{ account_code: "acc_x", provider: "swissquote" }])[0]).toMatchObject({ name: "Swissquote", currency: "USD", holding_codes: [] });
  });
});

describe("what a synced account covers", () => {
  const covered = brokerHoldingCodes(parseBrokerAccounts(RAW));
  it("leaves its holdings out of the list", () => {
    expect(outsideBrokers([{ holding_code: "hld_a" }, { holding_code: "hld_gold" }], covered)).toEqual([{ holding_code: "hld_gold" }]);
  });
  it("lists only live notes held elsewhere", () => {
    const notes = [
      { holding_code: "hld_a", status: "live" },
      { holding_code: "hld_c", status: "live" },
      { holding_code: "hld_d", status: "autocalled" },
    ];
    expect(liveNotesOutsideBrokers(notes, covered)).toEqual([{ holding_code: "hld_c", status: "live" }]);
    expect(liveNotesOutsideBrokers(notes.slice(0, 1), covered)).toEqual([]);
  });
});

describe("brokerRowFigures", () => {
  const usd = { currency: "USD", total: "113616.41", total_aed: "417256.27", profit: "18616.41", profit_aed: "68368.27", change_24h: "-327.50", change_24h_aed: "-1202.74", change_24h_pct: "-0.55", live_notes: "5" };

  it("leads with AED and keeps the account's own currency second", () => {
    expect(brokerRowFigures(usd)).toEqual({
      value: "AED 417,256",
      own: "USD 113,616",
      profit: "+AED 68,368",
      profitTone: "68368.27",
      change: "−AED 1,203",
      changePct: "−0.55%",
      changeTone: "-1202.74",
      notes: "5 live notes",
    });
  });

  it("shows INR second for Zerodha, and one live note in the singular", () => {
    const r = brokerRowFigures({ ...usd, currency: "INR", total: "1250000.00", total_aed: "55000.00", live_notes: "1" });
    expect([r.value, r.own, r.notes]).toEqual(["AED 55,000", "INR 1,250,000", "1 live note"]);
  });

  it("falls back to the account's currency for a figure the server sent no AED for", () => {
    const r = brokerRowFigures({ ...usd, total_aed: null, profit_aed: undefined, change_24h_aed: null });
    expect([r.value, r.own, r.profit, r.change]).toEqual(["USD 113,616", null, "+USD 18,616", "−USD 328"]);
  });

  it("leaves out what the server didn't send: no 24-hour change, no profit, no notes", () => {
    const r = brokerRowFigures({ currency: "USD", total: "100.00", total_aed: "367.25", profit: null, live_notes: "0" });
    expect([r.value, r.profit, r.change, r.changePct, r.notes]).toEqual(["AED 367", null, null, null, null]);
  });

  it("an AED account has no second currency", () => {
    const r = brokerRowFigures({ currency: "AED", total: "5000.00", total_aed: "5000.00", profit: "250.00", change_24h: "10.00", live_notes: null });
    expect([r.value, r.own, r.profit, r.change]).toEqual(["AED 5,000", null, "+AED 250", "+AED 10"]);
  });
});
