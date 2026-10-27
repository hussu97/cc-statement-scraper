// Daily closes from Yahoo Finance's chart endpoint (no key). Pure parsing, tested in
// _tests/stock_prices_test.ts.
//
// `close` is the official close, adjusted for splits but not dividends: the level a term sheet's
// initial fixing compares with until a split (then the note's levels need the same adjustment).
// A bar for a session still trading is the latest price, not a close, so it is dropped.

export interface Close {
  symbol: string;
  date: string; // the exchange's calendar day, YYYY-MM-DD
  close: string; // decimal string, 4 places (Yahoo serves float32)
  currency: string | null;
}

const HOSTS = ["query1.finance.yahoo.com", "query2.finance.yahoo.com"];

export function chartUrl(symbol: string, from: Date, to: Date, host = HOSTS[0]): string {
  const p1 = Math.floor(from.getTime() / 1000);
  const p2 = Math.floor(to.getTime() / 1000);
  return `https://${host}/v8/finance/chart/${encodeURIComponent(symbol)}?period1=${p1}&period2=${p2}&interval=1d`;
}

export const chartHosts = HOSTS;

interface ChartMeta {
  currency?: string;
  gmtoffset?: number;
  currentTradingPeriod?: { regular?: { start?: number; end?: number; gmtoffset?: number } };
}

interface ChartResponse {
  chart?: {
    result?: {
      meta?: ChartMeta;
      timestamp?: number[];
      indicators?: { quote?: { close?: (number | null)[] }[] };
    }[] | null;
    error?: { code?: string; description?: string } | null;
  };
}

function exchangeDay(epochSeconds: number, gmtoffset: number): string {
  return new Date((epochSeconds + gmtoffset) * 1000).toISOString().slice(0, 10);
}

/** The closes in a chart response; `now` decides whether the last session is still trading. */
export function parseChart(body: unknown, symbol: string, now = new Date()): Close[] {
  const chart = (body as ChartResponse)?.chart;
  if (chart?.error) {
    throw new Error(`yahoo ${symbol}: ${chart.error.code ?? "error"} ${chart.error.description ?? ""}`.trim());
  }
  const r = chart?.result?.[0];
  if (!r) throw new Error(`yahoo ${symbol}: no chart result`);
  const meta = r.meta ?? {};
  const offset = meta.gmtoffset ?? 0;
  const stamps = r.timestamp ?? [];
  const closes = r.indicators?.quote?.[0]?.close ?? [];
  const regular = meta.currentTradingPeriod?.regular;
  const nowSec = Math.floor(now.getTime() / 1000);
  const openDay = regular?.start && regular?.end && nowSec >= regular.start && nowSec < regular.end
    ? exchangeDay(regular.start, regular.gmtoffset ?? offset)
    : null;
  const byDay = new Map<string, Close>();
  stamps.forEach((ts, i) => {
    const c = closes[i];
    if (typeof c !== "number" || !Number.isFinite(c) || c <= 0) return;
    const date = exchangeDay(ts, offset);
    if (date === openDay) return;
    byDay.set(date, { symbol: symbol.toUpperCase(), date, close: c.toFixed(4), currency: meta.currency ?? null });
  });
  return [...byDay.values()].sort((a, b) => a.date.localeCompare(b.date));
}

// Bloomberg exchange codes → Yahoo suffixes. US composite / Nasdaq / NYSE codes take none.
const SUFFIX: Record<string, string> = {
  US: "",
  UW: "",
  UQ: "",
  UN: "",
  UA: "",
  UR: "",
  UP: "",
  UF: "",
  LN: ".L",
  GY: ".DE",
  GR: ".DE",
  FP: ".PA",
  NA: ".AS",
  SM: ".MC",
  IM: ".MI",
  SW: ".SW",
  SE: ".SW",
  VX: ".SW",
  JP: ".T",
  JT: ".T",
  HK: ".HK",
  CN: ".TO",
  CT: ".TO",
  AU: ".AX",
  AT: ".AX",
  SS: ".ST",
  DC: ".CO",
  FH: ".HE",
  NO: ".OL",
  BB: ".BR",
  ID: ".IR",
  PL: ".LS",
  KS: ".KS",
  TT: ".TW",
  SP: ".SI",
  UH: ".AE",
  DB: ".AE",
};

/** "GOOGL UW Equity" → "GOOGL"; "NESN SE Equity" → "NESN.SW"; "BRK/B UN" → "BRK-B". Null if unknown. */
export function bloombergToYahoo(code: string): string | null {
  const m = /^\s*([A-Z0-9/.]+)\s+([A-Z]{2})(?:\s+Equity)?\s*$/i.exec(code);
  if (!m) return null;
  const suffix = SUFFIX[m[2].toUpperCase()];
  if (suffix === undefined) return null;
  return m[1].toUpperCase().replace("/", "-") + suffix;
}
