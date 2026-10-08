// The ONE money formatter. Money arrives from the API either as a JSON number
// (numeric columns via PostgREST) or as a decimal string (jsonb payloads).
// Clients never do arithmetic on money; they only format what the server sent.

export type MoneyInput = number | string | null | undefined;

const formatters = new Map<string, Intl.NumberFormat>();

function formatter(currency: string, compact: boolean, fraction: number | undefined): Intl.NumberFormat {
  const key = `${currency}|${compact}|${fraction ?? "auto"}`;
  let f = formatters.get(key);
  if (!f) {
    try {
      f = new Intl.NumberFormat("en-US", {
        style: "currency",
        currency,
        currencyDisplay: "code",
        notation: compact ? "compact" : "standard",
        minimumFractionDigits: compact ? 0 : (fraction ?? 2),
        maximumFractionDigits: compact ? 1 : (fraction ?? 2),
      });
    } catch {
      // Unknown ISO code: fall back to a plain number with the code prefixed.
      f = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }
    formatters.set(key, f);
  }
  return f;
}

/** Parse an API money value for display. Returns null for empty/invalid input. */
export function toAmount(value: MoneyInput): number | null {
  if (value === null || value === undefined || value === "") return null;
  const n = typeof value === "number" ? value : Number(String(value).replace(/,/g, "").trim());
  return Number.isFinite(n) ? n : null;
}

export interface FormatMoneyOptions {
  currency?: string;
  /** Prefix + for positive values (credits). */
  signed?: boolean;
  /** 12.3K style. */
  compact?: boolean;
  /** Drop the currency code: "1,234.50". */
  bare?: boolean;
  /** Whole units only. */
  whole?: boolean;
  /** Placeholder for missing values. */
  empty?: string;
}

/** Format money: "AED 1,234.50". Never rounds beyond the API's 2 decimals. */
export function formatMoney(value: MoneyInput, opts: FormatMoneyOptions = {}): string {
  const n = toAmount(value);
  if (n === null) return opts.empty ?? "—";
  const currency = (opts.currency ?? "AED").toUpperCase();
  const f = formatter(currency, !!opts.compact, opts.whole ? 0 : undefined);
  const abs = Math.abs(n);
  let body = f.format(abs).replace(/\u00a0/g, " ");
  if (!/[A-Z]{3}/.test(body)) body = `${currency} ${body}`;
  if (opts.bare) body = body.replace(/^[A-Z]{3}\s?/, "").replace(/\s?[A-Z]{3}$/, "");
  const sign = n < 0 ? "−" : opts.signed && n > 0 ? "+" : "";
  return `${sign}${body}`;
}

/** Split a formatted amount into currency code and figure, for hero typography. */
export function moneyParts(value: MoneyInput, currency = "AED"): { currency: string; figure: string; negative: boolean } {
  const n = toAmount(value);
  if (n === null) return { currency, figure: "—", negative: false };
  return { currency, figure: formatMoney(Math.abs(n), { currency, bare: true }), negative: n < 0 };
}

/** Transaction amount from the ledger's point of view: credits shown with "+". */
export function formatTxnAmount(value: MoneyInput, direction: string | null | undefined, currency = "AED"): string {
  const n = toAmount(value);
  if (n === null) return "—";
  return direction === "credit" ? formatMoney(Math.abs(n), { currency, signed: true }) : formatMoney(Math.abs(n), { currency });
}

/** Display-only ratio between two server values (e.g. a progress bar width). */
export function displayRatio(part: MoneyInput, whole: MoneyInput): number | null {
  const a = toAmount(part);
  const b = toAmount(whole);
  if (a === null || b === null || b === 0) return null;
  return a / b;
}

export function formatPercent(ratio: number | string | null | undefined, digits = 0): string {
  const n = toAmount(ratio);
  if (n === null) return "—";
  return new Intl.NumberFormat("en-US", { style: "percent", maximumFractionDigits: digits, minimumFractionDigits: digits }).format(n);
}

/** "+12%" / "−8%" for a display delta between two server-provided amounts. */
export function formatDeltaPercent(current: MoneyInput, previous: MoneyInput): string | null {
  const c = toAmount(current);
  const p = toAmount(previous);
  if (c === null || p === null || p === 0) return null;
  const pct = Math.round(((c - p) / Math.abs(p)) * 100);
  if (pct === 0) return "±0%";
  return `${pct > 0 ? "+" : "−"}${Math.abs(pct)}%`;
}

export function formatCount(n: number | null | undefined): string {
  if (n === null || n === undefined) return "—";
  return new Intl.NumberFormat("en-US").format(n);
}

export function formatRate(rate: MoneyInput, digits = 4): string {
  const n = toAmount(rate);
  if (n === null) return "—";
  return n.toFixed(digits);
}
