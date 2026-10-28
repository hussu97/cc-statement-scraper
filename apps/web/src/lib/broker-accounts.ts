// Synced broker accounts on Investments (broker_accounts_summary): a tolerant reader, the account's
// row on Investments (AED first), and which holdings and notes it already covers, so Investments lists each once.
// Every figure is the server's (CLAUDE.md §2.2). Pure, unit-tested.
import { formatTotal, type MoneyInput } from "./money";
import { formatPct } from "./holdings";
import { isEnded } from "./notes";
import { providerLabel } from "./broker";

export interface BrokerAccountSummary {
  account_code: string;
  provider: string;
  bank_code: string | null;
  name: string;
  currency: string;
  cash: string | null;
  positions_value: string | null;
  total: string | null;
  total_aed: string | null;
  net_deposits: string | null;
  profit: string | null;
  /** The profit in AED; absent from an older server. */
  profit_aed?: string | null;
  /** The open positions' market move since the previous day's marks, in the account's currency, in AED and as a percent (×100); absent from an older server. */
  change_24h?: string | null;
  change_24h_aed?: string | null;
  change_24h_pct?: string | null;
  /** Counts, sent as strings like the money. */
  live_notes: string | null;
  positions: string | null;
  last_synced_at: string | null;
  sync_status: string | null;
  /** Every holding at the account, open or closed. */
  holding_codes: string[];
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown) => (typeof v === "string" ? v : typeof v === "number" ? String(v) : null);

/** broker_accounts_summary's jsonb as a list; anything that isn't an account is dropped, a missing list reads as empty. */
export function parseBrokerAccounts(raw: unknown): BrokerAccountSummary[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter(isObject).flatMap((a) => {
    const code = str(a.account_code);
    if (!code) return [];
    const provider = str(a.provider) ?? "broker";
    return [
      {
        account_code: code,
        provider,
        bank_code: str(a.bank_code),
        name: str(a.name) ?? providerLabel(provider),
        currency: str(a.currency) ?? "USD",
        cash: str(a.cash),
        positions_value: str(a.positions_value),
        total: str(a.total),
        total_aed: str(a.total_aed),
        net_deposits: str(a.net_deposits),
        profit: str(a.profit),
        profit_aed: str(a.profit_aed),
        change_24h: str(a.change_24h),
        change_24h_aed: str(a.change_24h_aed),
        change_24h_pct: str(a.change_24h_pct),
        live_notes: str(a.live_notes),
        positions: str(a.positions),
        last_synced_at: str(a.last_synced_at),
        sync_status: str(a.sync_status),
        holding_codes: Array.isArray(a.holding_codes) ? a.holding_codes.filter((c): c is string => typeof c === "string") : [],
      },
    ];
  });
}

/** Every holding a synced account covers. */
export function brokerHoldingCodes(accounts: readonly Pick<BrokerAccountSummary, "holding_codes">[]): Set<string> {
  return new Set(accounts.flatMap((a) => a.holding_codes));
}

/** The holdings a synced account doesn't cover (those are listed under the account, not one by one). */
export function outsideBrokers<T extends { holding_code: string }>(holdings: readonly T[], covered: ReadonlySet<string>): T[] {
  return holdings.filter((h) => !covered.has(h.holding_code));
}

/** Live notes not held at a synced account, for the Investments notes card; ended notes never list there. */
export function liveNotesOutsideBrokers<T extends { holding_code: string; status: string }>(notes: readonly T[], covered: ReadonlySet<string>): T[] {
  return notes.filter((n) => !isEnded(n.status) && !covered.has(n.holding_code));
}

/** A broker account's row on Investments, worded: AED first, the account's own currency second. */
export interface BrokerRowFigures {
  /** The account's worth: in AED, or in its own currency before an AED rate. */
  value: string | null;
  /** The own-currency worth under an AED one ("USD 113,616"); null for an AED account. */
  own: string | null;
  /** The profit, signed: in AED, or in the account's currency when the server sent no AED figure. */
  profit: string | null;
  profitTone: MoneyInput;
  /** The last 24 hours' market move, signed ("+AED 1,203"), with its percent ("+0.55%"); null when not sent. */
  change: string | null;
  changePct: string | null;
  changeTone: MoneyInput;
  /** "5 live notes"; null with none. */
  notes: string | null;
}

/** Each figure only when the server sent it (CLAUDE.md §2.2: nothing converted here). */
export function brokerRowFigures(
  a: Pick<BrokerAccountSummary, "total" | "total_aed" | "profit" | "profit_aed" | "change_24h" | "change_24h_aed" | "change_24h_pct" | "currency" | "live_notes">,
): BrokerRowFigures {
  const foreign = a.currency.toUpperCase() !== "AED";
  const ownTotal = a.total ? formatTotal(a.total, { currency: a.currency }) : null;
  const value = a.total_aed ? formatTotal(a.total_aed) : ownTotal;
  const profitAed = a.profit_aed ?? (foreign ? null : a.profit);
  const profitRaw = profitAed ?? a.profit;
  const profit = profitRaw ? formatTotal(profitRaw, { currency: profitAed ? "AED" : a.currency, signed: true }) : null;
  const changeAed = a.change_24h_aed ?? (foreign ? null : a.change_24h);
  const changeRaw = changeAed ?? a.change_24h ?? null;
  const change = changeRaw ? formatTotal(changeRaw, { currency: changeAed ? "AED" : a.currency, signed: true }) : null;
  const live = Number(a.live_notes);
  return {
    value,
    own: foreign && a.total_aed && ownTotal ? ownTotal : null,
    profit,
    profitTone: profitRaw,
    change,
    changePct: change ? formatPct(a.change_24h_pct, { signed: true }) : null,
    changeTone: changeRaw,
    notes: Number.isFinite(live) && live > 0 ? `${live} live note${live === 1 ? "" : "s"}` : null,
  };
}
