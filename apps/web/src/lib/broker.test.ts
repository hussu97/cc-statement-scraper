import { describe, expect, it } from "vitest";
import {
  dateTickFormatter,
  estimateNote,
  heldMonths,
  holdingResult,
  isLiveNote,
  parseBrokerPortfolio,
  pastHeadline,
  portfolioPoints,
  positionKind,
  providerLabel,
  splitPositions,
  syncStatus,
  type PortfolioDay,
} from "./broker";

// Invented round numbers, not anyone's real portfolio.
const RAW = {
  account_code: "acc_00000000000000000000000000",
  provider: "swissquote",
  portfolio_ref: "1000",
  currency: "USD",
  sync: { last_synced_at: "2026-10-27T10:00:00Z", last_attempt_at: "2026-10-27T10:00:00Z", status: "ok", error: null },
  as_of: "2026-10-27",
  cash: "1000.00",
  positions_value: "99000.00",
  total: "100000.00",
  total_aed: "367250.00",
  net_deposits: "90000.00",
  profit: "10000.00",
  income: "500.00",
  fees: "100.00",
  positions: [
    {
      holding_code: "hld_00000000000000000000000001",
      kind: "structured_note",
      name: "Test Autocall 2029",
      isin: "XS0000000001",
      symbol: "BSKT 29",
      quantity: "20000",
      price: "95.5",
      price_in_pct: true,
      currency: "USD",
      value: "19100.00",
      as_of: "2026-10-27",
      invested: "20000.00",
      income: "0",
      sell_now: { total: "19100.00", profit: "-900.00", return_pct: "-4.50" },
      note: {
        status: "live",
        next: null,
        worst_now: null,
        awaiting_prices: false,
        if_ended_today: null,
        if_called_next: {
          obs_date: "2027-03-15",
          pay_date: "2027-03-22",
          total: "22000.00",
          profit: "2000.00",
          coupons: "0.00",
          redemption: "22000.00",
          return_pct: "10.00",
          annualised_pct: "20.00",
          trigger_pct: "100",
          redemption_pct: "110",
        },
      },
    },
    { holding_code: "hld_00000000000000000000000002", kind: "security", name: "SHARE ORD", isin: "US0000000002", symbol: "SHR", quantity: "10", price: "200", price_in_pct: false, currency: "USD", value: "2000.00", sell_now: null },
  ],
  closed_total: { count: "1", invested: "10000.00", received: "11000.00", profit: "1000.00" },
  closed: [{ holding_code: "hld_00000000000000000000000003", kind: "structured_note", name: "Old note", invested: "10000.00", returned: "11000.00", income: "0", profit: "1000.00", return_pct: "10.00", annualised_pct: "12.00", opened_on: "2025-01-01", closed_on: "2025-11-01", note_status: "autocalled" }],
  series: [
    { as_of: "2026-10-26", total: "99000.00", cash: null, positions: null, net_deposits: "90000.00", estimated: true },
    { as_of: "2026-10-25", total: "98000.00", cash: null, positions: null, net_deposits: "90000.00", estimated: true },
    { as_of: "2026-10-27", total: "100000.00", cash: "1000.00", positions: "99000.00", net_deposits: "90000.00", estimated: false },
  ],
};

describe("parseBrokerPortfolio", () => {
  it("returns null for an account without a sync", () => {
    expect(parseBrokerPortfolio(null)).toBeNull();
    expect(parseBrokerPortfolio("nope")).toBeNull();
    expect(parseBrokerPortfolio({})).toBeNull();
  });

  it("keeps the server's decimal strings and sorts the series by day", () => {
    const p = parseBrokerPortfolio(RAW)!;
    expect(p.total).toBe("100000.00");
    expect(p.profit).toBe("10000.00");
    expect(p.positions).toHaveLength(2);
    expect(p.positions[1]!.note).toBeNull();
    expect(p.series.map((d) => d.as_of)).toEqual(["2026-10-25", "2026-10-26", "2026-10-27"]);
  });

  it("reads a partial payload as empty lists and never synced", () => {
    const p = parseBrokerPortfolio({ account_code: "acc_x", series: [{ total: "1" }, { as_of: "2026-01-01", total: "1" }] })!;
    expect(p.positions).toEqual([]);
    expect(p.closed).toEqual([]);
    expect(p.series).toHaveLength(1);
    expect(p.series[0]!.estimated).toBe(false);
    expect(p.sync).toEqual({ last_synced_at: null, last_attempt_at: null, status: null, error: null });
    expect(p.currency).toBe("USD");
  });
});

describe("syncStatus", () => {
  const now = new Date("2026-10-27T12:00:00Z");
  it("says when it last synced", () => {
    expect(syncStatus({ last_synced_at: "2026-10-27T10:00:00Z", last_attempt_at: null, status: "ok", error: null }, now)).toEqual({ text: "Synced 2 h ago", tone: "muted" });
  });
  it("shows the error when the last attempt failed", () => {
    const s = syncStatus({ last_synced_at: "2026-10-26T12:00:00Z", last_attempt_at: "2026-10-27T11:00:00Z", status: "error", error: "Login refused" }, now);
    expect(s.tone).toBe("danger");
    expect(s.text).toBe("Sync failed 1 h ago: Login refused; last good sync 24 h ago");
  });
  it("never synced", () => {
    expect(syncStatus({ last_synced_at: null, last_attempt_at: null, status: null, error: null }, now).text).toBe("Not synced yet");
    expect(syncStatus({ last_synced_at: null, last_attempt_at: null, status: "error", error: null }, now).text).toBe("Sync failed: no reason given");
  });
});

describe("positions", () => {
  const p = parseBrokerPortfolio(RAW)!;
  it("words a position's kind and provider", () => {
    expect(positionKind("structured_note")).toBe("structured_note");
    expect(positionKind("broker")).toBe("broker");
    expect(positionKind("something_new")).toBe("security");
    expect(providerLabel("swissquote")).toBe("Swissquote");
    expect(providerLabel(null)).toBe("Broker");
  });
  it("splits live notes from other holdings, in the server's order", () => {
    const ended = { ...p.positions[0]!, holding_code: "hld_ended", note: { ...p.positions[0]!.note!, status: "autocalled" } };
    const bare = { ...p.positions[0]!, holding_code: "hld_bare", note: null };
    const { notes, others } = splitPositions([p.positions[0]!, p.positions[1]!, ended, bare]);
    expect(notes.map((x) => x.holding_code)).toEqual(["hld_00000000000000000000000001"]);
    expect(others.map((x) => x.holding_code)).toEqual(["hld_00000000000000000000000002", "hld_ended", "hld_bare"]);
    expect(isLiveNote(p.positions[0]!)).toBe(true);
  });
  it("takes a holding's result from sell_now, else its profit", () => {
    expect(holdingResult(p.positions[0]!)).toEqual({ profit: "-900.00", returnPct: "-4.50" });
    expect(holdingResult({ sell_now: null, profit: "12.00" })).toEqual({ profit: "12.00", returnPct: null });
  });
  it("words how long a closed position was held", () => {
    expect(heldMonths(p.closed[0]!)).toBe("held Jan–Nov 2025");
    expect(heldMonths({ opened_on: "2025-11-03", closed_on: "2026-03-09" })).toBe("held Nov 2025–Mar 2026");
    expect(heldMonths({ opened_on: "2026-09-01", closed_on: "2026-09-20" })).toBe("held Sep 2026");
    expect(heldMonths({ opened_on: null, closed_on: null })).toBe("—");
  });
  it("sums up the past notes in one line", () => {
    expect(p.closed_total).toEqual({ count: "1", invested: "10000.00", received: "11000.00", profit: "1000.00" });
    expect(pastHeadline(p.closed_total, p.closed, "USD")).toBe("1 called early · +USD 1,000 earned on USD 10,000");
    expect(pastHeadline({ count: "2", invested: "100.00", received: "90.00", profit: "-10.00" }, [{ note_status: "autocalled" }, { note_status: null }], "USD")).toBe(
      "2 ended · −USD 10 lost on USD 100",
    );
    expect(pastHeadline(null, [], "USD")).toBeNull();
  });
});

describe("portfolio chart", () => {
  const day = (as_of: string, total: string, estimated: boolean): PortfolioDay => ({ as_of, total, cash: null, positions: null, net_deposits: "100.00", estimated });

  it("draws estimated days dashed and joins them to the first mark", () => {
    const pts = portfolioPoints([day("2026-01-01", "100.00", true), day("2026-01-02", "110.00", true), day("2026-01-03", "120.00", false), day("2026-01-04", "130.00", false)]);
    expect(pts.map((p) => p.estimated)).toEqual([100, 110, 120, null]);
    expect(pts.map((p) => p.marked)).toEqual([null, null, 120, 130]);
    expect(pts.map((p) => p.deposits)).toEqual([100, 100, 100, 100]);
  });

  it("puts the year on ticks when the series spans more than a year", () => {
    expect(dateTickFormatter([{ date: "2026-01-01" }, { date: "2026-06-01" }])("2026-03-09")).toBe("9 Mar");
    expect(dateTickFormatter([{ date: "2024-11-01" }, { date: "2026-10-27" }])("2024-12-09")).toBe("Dec ’24");
    expect(dateTickFormatter([])("2026-03-09")).toBe("9 Mar");
  });

  it("explains estimated days", () => {
    expect(estimateNote([day("2026-01-01", "1", false)])).toBeNull();
    expect(estimateNote([day("2026-01-01", "1", true)])).toBe("Every day is estimated from the broker's performance index.");
    expect(estimateNote([day("2026-01-01", "1", true), day("2026-01-02", "1", false)])).toBe(
      "Dashed: estimated from the broker's performance index before 2 Jan 2026; daily marks since.",
    );
  });
});
