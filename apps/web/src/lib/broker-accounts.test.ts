import { describe, expect, it } from "vitest";
import { brokerAccountLine, brokerHoldingCodes, liveNotesOutsideBrokers, outsideBrokers, parseBrokerAccounts } from "./broker-accounts";

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
    expect(parseBrokerAccounts(null)).toEqual([]);
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

describe("brokerAccountLine", () => {
  it("words the account in one line", () => {
    expect(brokerAccountLine({ total: "113616.41", profit: "18616.41", currency: "USD", live_notes: "5" })).toBe("USD 113,616 · +USD 18,616 · 5 live notes");
    expect(brokerAccountLine({ total: "100.00", profit: "-5.00", currency: "USD", live_notes: "1" })).toBe("USD 100 · −USD 5 · 1 live note");
    expect(brokerAccountLine({ total: "100.00", profit: null, currency: "USD", live_notes: "0" })).toBe("USD 100");
  });
});
