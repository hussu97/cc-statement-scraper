import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import { bloombergToYahoo, chartUrl, fetchFrom, parseChart } from "../stock-prices/yahoo.ts";

// The shape query1.finance.yahoo.com served for AMZN on 27 Oct 2026 (Dubai), trimmed.
const AMZN = {
  chart: {
    result: [{
      meta: {
        currency: "USD",
        symbol: "AMZN",
        gmtoffset: -14400,
        currentTradingPeriod: { regular: { start: 1793107800, end: 1793131200, gmtoffset: -14400 } },
      },
      timestamp: [1792589400, 1792675800, 1792762200, 1793021400],
      indicators: { quote: [{ close: [262.3699951171875, 250.3800048828125, null, 249.08999633789062] }] },
    }],
    error: null,
  },
};

Deno.test("parseChart: one close per exchange day, 4 places, nulls skipped", () => {
  assertEquals(parseChart(AMZN, "amzn", new Date("2026-10-27T08:00:00Z")), [
    { symbol: "AMZN", date: "2026-10-21", close: "262.3700", currency: "USD" },
    { symbol: "AMZN", date: "2026-10-22", close: "250.3800", currency: "USD" }, // Example Bank M's initial fixing
    { symbol: "AMZN", date: "2026-10-26", close: "249.0900", currency: "USD" },
  ]);
});

Deno.test("parseChart: a session still trading is not a close", () => {
  const live = structuredClone(AMZN);
  live.chart.result[0].timestamp.push(1793107800); // 27 Oct, 09:30 New York
  live.chart.result[0].indicators.quote[0].close.push(251.5);
  const during = parseChart(live, "AMZN", new Date("2026-10-27T15:00:00Z"));
  assertEquals(during.at(-1)?.date, "2026-10-26");
  const after = parseChart(live, "AMZN", new Date("2026-10-27T21:00:00Z"));
  assertEquals(after.at(-1), { symbol: "AMZN", date: "2026-10-27", close: "251.5000", currency: "USD" });
});

Deno.test("parseChart: Yahoo's error is the message", () => {
  assertThrows(
    () => parseChart({ chart: { result: null, error: { code: "Not Found", description: "No data found" } } }, "ZZZZ"),
    Error,
    "yahoo ZZZZ: Not Found No data found",
  );
});

Deno.test("chartUrl: seconds, daily interval, encoded symbol", () => {
  assertEquals(
    chartUrl("BRK-B", new Date("2026-01-01T00:00:00Z"), new Date("2026-01-02T00:00:00Z")),
    "https://query1.finance.yahoo.com/v8/finance/chart/BRK-B?period1=1767225600&period2=1767312000&interval=1d",
  );
});

Deno.test("bloombergToYahoo: US codes bare, others suffixed, unknown null", () => {
  assertEquals(bloombergToYahoo("GOOGL UW Equity"), "GOOGL");
  assertEquals(bloombergToYahoo("JPM UN Equity"), "JPM");
  assertEquals(bloombergToYahoo("ORCL UN"), "ORCL");
  assertEquals(bloombergToYahoo("NESN SE Equity"), "NESN.SW");
  assertEquals(bloombergToYahoo("BRK/B UN Equity"), "BRK-B");
  assertEquals(bloombergToYahoo("XYZ QQ Equity"), null);
  assertEquals(bloombergToYahoo("Amazon.com Inc"), null);
});

Deno.test("fetchFrom: back to the strike when the stored closes start later, else 5 days before the last", () => {
  const s = { symbol: "AMZN", from_date: "2026-01-08", first_date: "2026-08-06", last_date: "2026-10-26" };
  assertEquals(fetchFrom(s).toISOString().slice(0, 10), "2026-01-08");
  assertEquals(fetchFrom({ ...s, first_date: "2026-01-05" }).toISOString().slice(0, 10), "2026-10-21");
  assertEquals(fetchFrom({ ...s, first_date: null, last_date: null }).toISOString().slice(0, 10), "2026-01-08");
});
