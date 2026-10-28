import { describe, expect, it } from "vitest";
import {
  aedLine,
  changeText,
  formatInr,
  indiaAccountFor,
  indiaAccountTab,
  indiaPeriodParam,
  indiaPoints,
  indiaSegment,
  indiaTabPath,
  parseIndiaAccountSearch,
  parseIndiaOverview,
  parseIndiaSearch,
  periodFigures,
  positionsText,
} from "./india";

const account = (over: Record<string, unknown> = {}) => ({
  account_code: "acc_01KITE00000000000000000000",
  bank_code: "KITE",
  name: "Zerodha Kite",
  segment: "kite",
  value: "125000.50",
  value_aed: "5500.10",
  invested: "100000.00",
  cash: "2500.00",
  pnl: "22500.50",
  pnl_pct: "22.50",
  change_24h: "-350.00",
  change_24h_pct: "-0.28",
  positions: "8",
  last_synced_at: "2026-10-28T04:00:00Z",
  sync_status: "ok",
  ...over,
});

const PAYLOAD = {
  available: true,
  currency: "INR",
  period: "30d",
  from: "2026-09-28",
  to: "2026-10-28",
  total: {
    value: "200000.00",
    value_aed: "8800.00",
    invested: "170000.00",
    cash: "2500.00",
    pnl: "27500.00",
    pnl_pct: "16.18",
    change_24h: "-500.00",
    change_24h_aed: "-22.00",
    change_24h_pct: "-0.25",
    period_start_value: "180000.00",
    period_end_value: "200000.00",
    period_added: "15000.00",
    period_growth: "5000.00",
    period_growth_pct: "2.56",
    positions: "12",
    last_synced_at: "2026-10-28T04:00:00Z",
  },
  accounts: [
    account({ account_code: "acc_02COIN00000000000000000000", bank_code: "COIN", name: "Zerodha Coin", segment: "coin" }),
    account(),
  ],
  series: [
    { date: "2026-10-28", value: "200000.00", invested: "170000.00" },
    { date: "2026-09-28", value: "180000.00", invested: "155000.00" },
  ],
};

describe("parseIndiaOverview", () => {
  it("reads the contract's payload, Kite before Coin and days in order", () => {
    const o = parseIndiaOverview(PAYLOAD);
    expect(o.available).toBe(true);
    expect(o.currency).toBe("INR");
    expect(o.period).toBe("30d");
    expect(o.from).toBe("2026-09-28");
    expect(o.total.value).toBe("200000.00");
    expect(o.total.period_growth_pct).toBe("2.56");
    expect(o.total.last_synced_at).toBe("2026-10-28T04:00:00Z");
    expect(o.accounts.map((a) => a.segment)).toEqual(["kite", "coin"]);
    expect(o.series.map((d) => d.date)).toEqual(["2026-09-28", "2026-10-28"]);
  });

  it("keeps money as decimal strings and refuses floats and junk", () => {
    const o = parseIndiaOverview({ ...PAYLOAD, total: { ...PAYLOAD.total, value: 200000.1, pnl: "lots", invested: " 170000.00 " } });
    expect(o.total.value).toBeNull();
    expect(o.total.pnl).toBeNull();
    expect(o.total.invested).toBe("170000.00");
    expect(typeof o.accounts[0]?.value).toBe("string");
  });

  it("reads anything that isn't an overview as no India", () => {
    for (const raw of [null, undefined, "x", [], { available: "true" }]) {
      const o = parseIndiaOverview(raw);
      expect(o.available).toBe(false);
      expect(o.accounts).toEqual([]);
      expect(o.series).toEqual([]);
      expect(o.total.value).toBeNull();
      expect(o.period).toBe("90d");
    }
  });

  it("drops an account without a code and a day without a date; names a nameless account", () => {
    const o = parseIndiaOverview({
      ...PAYLOAD,
      accounts: [{ bank_code: "KITE" }, account({ name: null, segment: null, bank_code: "COIN" })],
      series: [{ value: "1" }, { date: "junk", value: "1" }, { date: "2026-10-01", value: "1", invested: null }],
    });
    expect(o.accounts).toHaveLength(1);
    expect(o.accounts[0]?.name).toBe("Zerodha Coin");
    expect(o.series).toEqual([{ date: "2026-10-01", value: "1", invested: null }]);
  });
});

describe("accounts and tabs", () => {
  it("files an account under Kite or Coin by segment, else by bank", () => {
    expect(indiaSegment({ segment: "kite" })).toBe("kite");
    expect(indiaSegment({ segment: "COIN" })).toBe("coin");
    expect(indiaSegment({ segment: null, bank_code: "KITE" })).toBe("kite");
    expect(indiaSegment({ segment: null, bank_code: "coin" })).toBe("coin");
    expect(indiaSegment({ segment: "other", bank_code: "ZRD" })).toBeNull();
  });

  it("links a row to its tab, or nowhere", () => {
    expect(indiaTabPath({ segment: "kite" })).toBe("/india/kite");
    expect(indiaTabPath({ bank_code: "COIN" })).toBe("/india/coin");
    expect(indiaTabPath({ bank_code: "ZRD" })).toBeNull();
  });

  it("finds the tab's account by segment", () => {
    const o = parseIndiaOverview(PAYLOAD);
    expect(indiaAccountFor(o.accounts, "kite")?.account_code).toBe("acc_01KITE00000000000000000000");
    expect(indiaAccountFor(o.accounts, "coin")?.account_code).toBe("acc_02COIN00000000000000000000");
    expect(indiaAccountFor(o.accounts.slice(0, 1), "coin")).toBeNull();
  });
});

describe("search codecs", () => {
  it("keeps a known period other than the default, and drops the rest as undefined", () => {
    expect(parseIndiaSearch({ period: "30d" })).toEqual({ period: "30d" });
    expect(parseIndiaSearch({ period: "ytd" })).toEqual({ period: "ytd" });
    expect(parseIndiaSearch({ period: "12m" })).toEqual({ period: "12m" });
    // undefined, not absent: it must override the raw URL the root route passes through.
    expect(parseIndiaSearch({ period: "90d" })).toHaveProperty("period", undefined);
    expect(parseIndiaSearch({ period: "all" })).toHaveProperty("period", undefined);
    expect(parseIndiaSearch({})).toHaveProperty("period", undefined);
  });

  it("leaves the default period out of the URL", () => {
    expect(indiaPeriodParam("90d")).toBeUndefined();
    expect(indiaPeriodParam("30d")).toBe("30d");
  });

  it("reads the account tab: Past, else Portfolio", () => {
    expect(indiaAccountTab("past")).toBe("past");
    expect(indiaAccountTab("transactions")).toBe("portfolio");
    expect(indiaAccountTab(undefined)).toBe("portfolio");
    expect(parseIndiaAccountSearch({ tab: "past" })).toEqual({ tab: "past" });
    expect(parseIndiaAccountSearch({ tab: "junk" })).toHaveProperty("tab", undefined);
  });
});

describe("wording", () => {
  it("shows totals in INR, whole units, and the AED line under them", () => {
    expect(formatInr("125000.50")).toBe("INR 125,001");
    expect(formatInr(null)).toBe("—");
    expect(formatInr("-350", { signed: true })).toBe("−INR 350");
    expect(aedLine("5500.10")).toBe("≈ AED 5,500");
    expect(aedLine("-22", { signed: true })).toBe("≈ −AED 22");
    expect(aedLine(null)).toBe("No AED rate yet");
  });

  it("words a P&L or move with its percentage, or nothing when unknown", () => {
    expect(changeText("22500.50", "22.50")).toBe("+INR 22,501 (+22.5%)");
    expect(changeText("-350.00", "-0.28")).toBe("−INR 350 (−0.28%)");
    expect(changeText("100", null)).toBe("+INR 100");
    expect(changeText(null, "1")).toBeNull();
  });

  it("words the period's returns", () => {
    const f = periodFigures(parseIndiaOverview(PAYLOAD).total);
    expect(f).toEqual({ start: "INR 180,000", end: "INR 200,000", added: "+INR 15,000", growth: "+INR 5,000", growthPct: "+2.56%" });
    expect(periodFigures({ period_start_value: null, period_end_value: null, period_added: null, period_growth: null, period_growth_pct: null }).growthPct).toBeNull();
  });

  it("counts positions", () => {
    expect(positionsText("1")).toBe("1 position");
    expect(positionsText("12")).toBe("12 positions");
    expect(positionsText(null)).toBeNull();
  });

  it("turns the series into points for drawing, a missing value a gap", () => {
    expect(indiaPoints([{ date: "2026-10-01", value: "10.50", invested: null }])).toEqual([{ date: "2026-10-01", value: 10.5, invested: null }]);
  });
});
