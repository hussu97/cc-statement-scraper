import { describe, expect, it } from "vitest";
import { parseBrokerPortfolio, parseSips, showsCash } from "./broker";
import {
  allocationBars,
  assetLabel,
  parsePositionDetail,
  positionLine,
  positionPoints,
  positionSort,
  positionSortParam,
  priceLine,
  sipSchedule,
  sipStatus,
  sipStepUp,
  sortPositions,
  trimPrice,
  istDay,
} from "./broker-detail";
import { parseIndiaAccountSearch } from "./india";

const pos = (name: string, value: string | null, ret: string | null, today: string | null, weight: string | null) => ({
  name,
  value,
  return_pct: ret,
  day_change_pct: today,
  weight_pct: weight,
});

describe("positions list", () => {
  it("sort codec: a known sort, else value; the default leaves the URL", () => {
    expect(positionSort("today")).toBe("today");
    expect(positionSort("junk")).toBe("value");
    expect(positionSort(undefined)).toBe("value");
    expect(positionSortParam("value")).toBeUndefined();
    expect(positionSortParam("return")).toBe("return");
    expect(parseIndiaAccountSearch({ sort: "weight", tab: "past" })).toEqual({ tab: "past", sort: "weight" });
    expect(parseIndiaAccountSearch({ sort: "junk" })).toEqual({ tab: undefined, sort: undefined });
    expect(parseIndiaAccountSearch({ sort: "value" })).toEqual({ tab: undefined, sort: undefined });
  });

  it("sorts the server's numbers largest first, unknowns last; names A–Z", () => {
    const rows = [pos("Beta", "100", "-5.5", null, "10"), pos("alpha", "300", "12", "1.2", "30"), pos("Gamma", "200", "40", "-0.4", "20")];
    expect(sortPositions(rows, "value").map((r) => r.name)).toEqual(["alpha", "Gamma", "Beta"]);
    expect(sortPositions(rows, "return").map((r) => r.name)).toEqual(["Gamma", "alpha", "Beta"]);
    expect(sortPositions(rows, "today").map((r) => r.name)).toEqual(["alpha", "Gamma", "Beta"]);
    expect(sortPositions(rows, "name").map((r) => r.name)).toEqual(["alpha", "Beta", "Gamma"]);
    expect(rows[0]!.name).toBe("Beta");
  });
});

describe("words", () => {
  it("asset label", () => {
    expect([assetLabel("stock"), assetLabel("etf"), assetLabel("fund"), assetLabel(null)]).toEqual(["Stock", "ETF", "Fund", null]);
  });

  it("a position in one line: ticker and exchange, ETF marked; a fund's type and house; else its ISIN", () => {
    expect(positionLine({ asset_class: "stock", symbol: "ACMEAD", exchange: "NSE", category: null, issuer: null, isin: "INE000G01010" })).toBe("ACMEAD · NSE");
    expect(positionLine({ asset_class: "etf", symbol: "NIFTYBEES", exchange: "BSE", category: null, issuer: null, isin: "INF204KB14I2" })).toBe("ETF · NIFTYBEES · BSE");
    expect(positionLine({ asset_class: "fund", symbol: "INF000B01014", exchange: null, category: "Equity", issuer: "Northwind Mutual Fund", isin: "INF000B01014" })).toBe(
      "Equity · Northwind Mutual Fund",
    );
    expect(positionLine({ asset_class: null, symbol: null, exchange: null, category: null, issuer: null, isin: "INE000A01073" })).toBe("INE000A01073");
  });

  it("price: 2–4 decimals; a fund's NAV with its date", () => {
    expect(trimPrice("193.82730000")).toBe("193.8273");
    expect(trimPrice("240.05000000")).toBe("240.05");
    expect(trimPrice("1372.7")).toBe("1,372.70");
    expect(priceLine({ price: "193.8273", price_date: "2026-10-27", asset_class: "fund" }, "INR")).toBe("INR 193.8273 NAV on 27 Oct");
    expect(priceLine({ price: "49.05", price_date: null, asset_class: "fund" }, "inr")).toBe("INR 49.05 NAV");
    expect(priceLine({ price: "240.05", price_date: null, asset_class: "stock" }, "INR")).toBe("INR 240.05");
    expect(priceLine({ price: null, price_date: null, asset_class: "stock" }, "INR")).toBe("—");
  });
});

describe("SIPs", () => {
  const sip = {
    sip_code: "bsp_1",
    isin: "INF000C01012",
    fund: "Initech Large & Mid Cap Fund",
    holding_code: "hld_1",
    status: "active",
    frequency: "monthly",
    amount: "2184.00",
    currency: "INR",
    day: "5",
    next_instalment: "2026-11-05",
    last_instalment: "2026-10-05T01:50:30+05:30",
    completed: "68",
    step_up: { "10-02": "3" },
    started_at: null,
    last_order: null,
    missed: false,
  };

  it("schedule: amount, frequency and day", () => {
    expect(sipSchedule(sip)).toBe("INR 2,184 monthly, on the 5th");
    expect(sipSchedule({ ...sip, day: "1" })).toBe("INR 2,184 monthly, on the 1st");
    expect(sipSchedule({ ...sip, day: "22" })).toBe("INR 2,184 monthly, on the 22nd");
    expect(sipSchedule({ ...sip, day: "11" })).toBe("INR 2,184 monthly, on the 11th");
    expect(sipSchedule({ ...sip, frequency: "weekly", day: "2" })).toBe("INR 2,184 weekly");
  });

  it("step-up: rate and date; none without one", () => {
    expect(sipStepUp(sip.step_up)).toBe("Steps up 3% every 2 Oct");
    expect(sipStepUp({ "04-10": "10" })).toBe("Steps up 10% every 10 Apr");
    expect(sipStepUp(null)).toBeNull();
    expect(sipStepUp({ junk: "3" })).toBeNull();
  });

  it("status: a rejected instalment is a warning with its reason; else the count and next date", () => {
    expect(sipStatus(sip)).toEqual({ text: "68 instalments so far · next 5 Nov", tone: "positive" });
    expect(
      sipStatus({ ...sip, missed: true, last_order: { status: "rejected", message: "Payment not received.", at: "2026-10-05T01:50:30+05:30" } }),
    ).toEqual({ text: "The 5 Oct instalment was rejected: Payment not received", tone: "danger" });
    // 1 Oct 01:41 IST is 30 Sep in Dubai and UTC: the instalment keeps India's date.
    expect(sipStatus({ ...sip, missed: true, last_order: { status: "rejected", message: null, at: "2026-09-30T20:11:05+00:00" } }).text).toBe(
      "The 1 Oct instalment was rejected",
    );
    expect(istDay("2026-09-30T20:11:05+00:00")).toBe("2026-10-01");
    expect(istDay(null)).toBeNull();
    expect(sipStatus({ ...sip, status: "paused" }).text).toBe("Paused");
    expect(sipStatus({ ...sip, status: "cancelled" }).text).toBe("Cancelled");
  });

  it("parseSips: tolerant; missed only when true", () => {
    expect(parseSips([sip, { fund: "no code" }, "junk"]).length).toBe(1);
    expect(parseSips([{ ...sip, missed: "yes", step_up: "x" }])[0]).toMatchObject({ missed: false, step_up: null });
    expect(parseSips(null)).toEqual([]);
  });
});

describe("portfolio additions", () => {
  it("parses day change, allocation, fund houses, highlights and SIPs; an older payload reads as none", () => {
    const p = parseBrokerPortfolio({
      account_code: "acc_1",
      basis: "cost",
      day_change: "-817.98",
      day_change_pct: "-0.20",
      allocation: [{ key: "stock", label: "Stocks", value: "100", weight_pct: "76.57" }, { label: "no key" }],
      issuers: [{ issuer: "Acme Mutual Fund", value: "10", weight_pct: "12" }],
      highlights: { best: [{ name: "TESTSHOP", return_pct: "318.17" }], worst: "x", top5_weight_pct: "31.22" },
      sips: [{ sip_code: "bsp_1", fund: "F", status: "active", missed: true }],
    })!;
    expect([p.day_change, p.day_change_pct]).toEqual(["-817.98", "-0.20"]);
    expect(p.allocation.map((a) => a.key)).toEqual(["stock"]);
    expect(p.issuers.length).toBe(1);
    expect(p.highlights).toMatchObject({ best: [{ name: "TESTSHOP" }], worst: [], gainers_today: [], top5_weight_pct: "31.22" });
    expect(p.sips[0]!.missed).toBe(true);
    const old = parseBrokerPortfolio({ account_code: "acc_1" })!;
    expect([old.day_change, old.allocation, old.highlights, old.sips]).toEqual([null, [], null, []]);
  });

  it("cash shows except where an account against cost holds none (Coin)", () => {
    expect(showsCash({ basis: "cost", cash: "0.00" })).toBe(false);
    expect(showsCash({ basis: "cost", cash: null })).toBe(false);
    expect(showsCash({ basis: "cost", cash: "18643.80" })).toBe(true);
    expect(showsCash({ basis: "deposits", cash: "0.00" })).toBe(true);
  });

  it("allocation bars: palette in order, width clamped to 0–100", () => {
    const bars = allocationBars([
      { key: "a", label: "A", positions: "1", value: "1", weight_pct: "76.57", invested: null, profit: null, return_pct: null },
      { key: "b", label: "B", positions: "1", value: "1", weight_pct: "130", invested: null, profit: null, return_pct: null },
      { key: "c", label: "C", positions: "1", value: "1", weight_pct: null, invested: null, profit: null, return_pct: null },
    ]);
    expect(bars.map((b) => [b.color, b.width])).toEqual([
      ["var(--chart-cat-1)", 76.57],
      ["var(--chart-cat-2)", 100],
      ["var(--chart-cat-3)", 0],
    ]);
  });
});

describe("one position", () => {
  it("parsePositionDetail: the position, its marks in date order, its SIPs; null when never marked", () => {
    const d = parsePositionDetail({
      account_code: "acc_1",
      isin: "INF000B01014",
      name: "Northwind",
      currency: "INR",
      position: { name: "Northwind", value: "353841.62" },
      series: [
        { as_of: "2026-10-28", value: "353841.62", cost: "114395.56", price: "193.8273" },
        { as_of: "2026-10-27", value: "350000.00", cost: "114395.56" },
        { value: "no date" },
      ],
      sips: [],
    })!;
    expect(d.position?.value).toBe("353841.62");
    expect(d.series.map((x) => x.as_of)).toEqual(["2026-10-27", "2026-10-28"]);
    expect(parsePositionDetail(null)).toBeNull();
    expect(parsePositionDetail({ account_code: "acc_1", isin: "X", position: "gone" })!.position).toBeNull();
  });

  it("positionPoints: worth against cost for the chart", () => {
    const pts = positionPoints([{ as_of: "2026-10-27", price: null, price_date: null, quantity: "1", value: "350000.00", cost: "114395.56" }]);
    expect(pts[0]).toMatchObject({ date: "2026-10-27", marked: 350000, deposits: 114395.56, estimated: null, isEstimated: false });
    expect(pts[0]!.day).toMatchObject({ positions: "350000.00", invested: "114395.56", estimated: false });
  });
});
