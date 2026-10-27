// Synced broker accounts on Investments (broker_accounts_summary): a tolerant reader, the account's
// one-line summary, and which holdings and notes it already covers, so Investments lists each once.
// Every figure is the server's (CLAUDE.md §2.2). Pure, unit-tested.
import { formatTotal } from "./money";
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

/** "USD 113,616 · +USD 18,616 · 5 live notes" (each part only when the server sent it). */
export function brokerAccountLine(a: Pick<BrokerAccountSummary, "total" | "profit" | "currency" | "live_notes">): string {
  const parts: string[] = [];
  if (a.total) parts.push(formatTotal(a.total, { currency: a.currency }));
  if (a.profit) parts.push(formatTotal(a.profit, { currency: a.currency, signed: true }));
  const live = Number(a.live_notes);
  if (Number.isFinite(live) && live > 0) parts.push(`${live} live note${live === 1 ? "" : "s"}`);
  return parts.join(" · ");
}
