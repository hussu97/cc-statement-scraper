// Cash flow and bank-account display helpers (Phase 2d). Pure, unit-tested. The figures are the
// server's (public.cash_flow, public.cash_position): nothing here adds money up (CLAUDE.md §2.2).
import { addMonths, formatMonth, isISODate, monthEnd, todayDubai, type ISODate } from "./dates";
import { formatTotal, toAmount, type MoneyInput } from "./money";

/** Every flow `cash_flow` returns, plus its per-month `net` row. */
export const FLOWS = [
  "income",
  "money_in",
  "support",
  "saving",
  "spend",
  "spend_transfer",
  "money_out",
  "card_repayment",
  "internal_in",
  "internal_out",
] as const;
export type Flow = (typeof FLOWS)[number];

export interface FlowInfo {
  label: string;
  /** Money into (+) or out of (−) the ledger's accounts, for the sign shown. */
  direction: "in" | "out";
  /** Not filed under a category yet: links to Activity's Uncategorised. */
  unfiled?: boolean;
}

export const FLOW_INFO: Record<Flow, FlowInfo> = {
  income: { label: "Income", direction: "in" },
  money_in: { label: "Unfiled in", direction: "in", unfiled: true },
  support: { label: "Support", direction: "out" },
  saving: { label: "Saving", direction: "out" },
  spend: { label: "Spending", direction: "out" },
  spend_transfer: { label: "Spent by transfer", direction: "out" },
  money_out: { label: "Unfiled out", direction: "out", unfiled: true },
  card_repayment: { label: "Card repayments", direction: "out" },
  internal_in: { label: "From your own accounts", direction: "in" },
  internal_out: { label: "To your own accounts", direction: "out" },
};

export type FlowGroupKey = "in" | "committed" | "spent" | "unfiled_out" | "moves";

/** The page's five groups, in display order. Moves never change net. */
export const FLOW_GROUPS: { key: FlowGroupKey; label: string; flows: readonly Flow[]; muted?: boolean; note?: string }[] = [
  { key: "in", label: "Money in", flows: ["income", "money_in"] },
  { key: "committed", label: "Committed", flows: ["support", "saving"] },
  { key: "spent", label: "Spent", flows: ["spend", "spend_transfer"] },
  { key: "unfiled_out", label: "Unfiled out", flows: ["money_out"] },
  { key: "moves", label: "Moves", flows: ["card_repayment", "internal_in", "internal_out"], muted: true, note: "Doesn't change net" },
];

export interface CashFlowRow {
  month: string;
  flow: string;
  amount_aed: MoneyInput;
  txn_count: number;
  /**
   * The month starts before the ledger's (or the account's) first bank evidence: card spend with no
   * income captured, so its net is not a loss. Optional: an older server omits it.
   */
  is_partial?: boolean;
}

export interface FlowLine {
  flow: Flow;
  label: string;
  direction: "in" | "out";
  unfiled: boolean;
  amount: MoneyInput;
  count: number;
}

export interface FlowGroup {
  key: FlowGroupKey;
  label: string;
  muted: boolean;
  note: string | null;
  lines: FlowLine[];
}

export interface MonthFlows {
  groups: FlowGroup[];
  /** The server's net for the month; null when nothing moved. */
  net: MoneyInput;
  hasMovements: boolean;
  /** Before the first bank evidence: money in wasn't captured, so the net isn't a loss (is_partial). */
  partial: boolean;
}

/**
 * One month's rows in the five groups. Each line is a server total; a flow the month doesn't have
 * is left out, and so is a group with no lines. A flow this web doesn't know yet is ignored rather
 * than filed somewhere wrong.
 */
export function monthFlows(rows: readonly CashFlowRow[], month: ISODate): MonthFlows {
  const mine = rows.filter((r) => r.month.slice(0, 10) === month);
  const byFlow = new Map(mine.map((r) => [r.flow, r]));
  const groups = FLOW_GROUPS.map((g) => ({
    key: g.key,
    label: g.label,
    muted: !!g.muted,
    note: g.note ?? null,
    lines: g.flows
      .filter((f) => byFlow.has(f))
      .map((f) => {
        const r = byFlow.get(f)!;
        return { flow: f, ...FLOW_INFO[f], unfiled: !!FLOW_INFO[f].unfiled, amount: r.amount_aed, count: r.txn_count };
      }),
  })).filter((g) => g.lines.length > 0);
  const net = byFlow.get("net");
  return { groups, net: net ? net.amount_aed : null, hasMovements: groups.length > 0, partial: mine.some((r) => r.is_partial === true) };
}

/** "+AED 50,000" for money in, "−AED 23,700" for money out (a negative out, e.g. refunds, reads "+"). */
export function formatFlow(amount: MoneyInput, direction: "in" | "out"): string {
  const n = toAmount(amount);
  if (n === null) return "—";
  return formatTotal(direction === "out" ? -n : n, { signed: true });
}

/** "+AED 1,200" / "−AED 300" / "AED 0" for a month's net; "—" when nothing moved. */
export function formatNet(net: MoneyInput): string {
  return toAmount(net) === null ? "—" : formatTotal(net, { signed: true });
}

export function netTone(net: MoneyInput): "positive" | "danger" | "neutral" {
  const n = toAmount(net);
  return n === null || n === 0 ? "neutral" : n > 0 ? "positive" : "danger";
}

/** How many months the page fetches and the net table lists, ending at the selected month. */
export const NET_MONTHS = 6;

/** The date range to fetch for a selected month: the NET_MONTHS months up to and including it. */
export function cashFlowRange(month: ISODate): { from: ISODate; to: ISODate } {
  return { from: addMonths(month, -(NET_MONTHS - 1)), to: monthEnd(month) };
}

export interface NetRow {
  month: ISODate;
  label: string;
  net: MoneyInput;
  /** Before the first bank evidence (is_partial): shown muted, never as a loss. */
  partial: boolean;
}

/** The month-by-month net table, newest first. A month with no movement has a null net. */
export function netByMonth(rows: readonly CashFlowRow[], month: ISODate): NetRow[] {
  const nets = new Map(rows.filter((r) => r.flow === "net").map((r) => [r.month.slice(0, 10), r]));
  return Array.from({ length: NET_MONTHS }, (_, i) => {
    const m = addMonths(month, -i);
    const r = nets.get(m);
    return { month: m, label: formatMonth(m, "short"), net: r ? r.amount_aed : null, partial: r?.is_partial === true };
  });
}

export interface CashFlowSearch {
  /** A first-of-month (YYYY-MM-01) no later than this month; absent = this month. */
  month?: string;
  /** One bank account (cash_flow's p_account_code); absent = every account. */
  account?: string;
}

const ACC_RE = /^acc_[0-9a-z]{26}$/;

/**
 * `/wealth/cash-flow?month=YYYY-MM-01&account=acc_…`. A dropped key comes back as undefined, so
 * it overrides the raw URL the root route passes through (tasks/lessons.md, TanStack Router).
 */
export function parseCashFlowSearch(raw: Record<string, unknown>, today: ISODate = todayDubai()): CashFlowSearch {
  const m = raw.month;
  const month = typeof m === "string" && /^\d{4}-\d{2}-01$/.test(m) && isISODate(m) && m <= today ? m : undefined;
  const account = typeof raw.account === "string" && ACC_RE.test(raw.account) ? raw.account : undefined;
  return { month, account };
}

// ── one transaction's flow (account ledger chips) ──────────────────────────

export interface FlowChip {
  label: string;
  tone: "neutral" | "positive" | "warn" | "info" | "accent";
}

/** A ledger row's flow, as a chip: the cash-flow vocabulary for one transaction. */
export const FLOW_CHIP: Record<Flow, FlowChip> = {
  spend: { label: "Spent", tone: "neutral" },
  income: { label: "Income", tone: "positive" },
  money_in: { label: "Money in (unfiled)", tone: "warn" },
  internal_in: { label: "From your account", tone: "neutral" },
  internal_out: { label: "To your account", tone: "neutral" },
  card_repayment: { label: "Card repayment", tone: "neutral" },
  support: { label: "Support", tone: "info" },
  saving: { label: "Saving", tone: "accent" },
  spend_transfer: { label: "Spent by transfer", tone: "neutral" },
  money_out: { label: "Money out (unfiled)", tone: "warn" },
};

export function isFlow(v: unknown): v is Flow {
  return typeof v === "string" && (FLOWS as readonly string[]).includes(v);
}

/** The chip for a row's flow; null for no flow (void, or a flow this web doesn't know yet). */
export function flowChip(flow: string | null | undefined): FlowChip | null {
  return isFlow(flow) ? FLOW_CHIP[flow] : null;
}

// ── bank accounts ──────────────────────────────────────────────────────────

export type BankAccountKind = "current" | "savings";
export const BANK_ACCOUNT_KINDS: { value: BankAccountKind; label: string }[] = [
  { value: "current", label: "Current" },
  { value: "savings", label: "Savings" },
];

/** A bank account's name: its nickname, else "Current ··· 310001" (or "Savings account"). */
export function bankAccountLabel(a: { kind?: string | null; nickname?: string | null; account_ref?: string | null }): string {
  const nick = a.nickname?.trim();
  if (nick) return nick;
  const kind = a.kind === "savings" ? "Savings" : "Current";
  return a.account_ref ? `${kind} ··· ${a.account_ref}` : `${kind} account`;
}

/** Where a balance came from, in a couple of words. */
export function balanceSourceLabel(source: string | null | undefined): string | null {
  if (source === "sms") return "from SMS";
  if (source === "manual") return "entered";
  if (source === "statement") return "from statement";
  // The broker's own cash figure, recorded at each sync (20261027165732_swissquote_sync.sql).
  if (source === "broker") return "from broker sync";
  return null;
}

/** Why the cash total may not be the whole story, or null when it is. */
export function cashCaveat(p: { complete: boolean; stale_count: number; missing_count: number }): string | null {
  const parts: string[] = [];
  if (p.missing_count > 0) parts.push(`${p.missing_count} ${p.missing_count === 1 ? "account has" : "accounts have"} no balance yet`);
  if (p.stale_count > 0) parts.push(`${p.stale_count} ${p.stale_count === 1 ? "balance is" : "balances are"} over a week old`);
  if (!parts.length && !p.complete) parts.push("Some amounts have no AED value yet");
  if (!parts.length) return null;
  const s = parts.join("; ");
  return s.charAt(0).toUpperCase() + s.slice(1);
}

/** The digits after the bank's mask: spaces, dashes and a leading X mask are dropped. */
export function normalizeAccountRef(v: string): string {
  return v.replace(/[\s-]/g, "").replace(/^[xX*•]+/, "");
}

/** Validate the Add bank account form. Returns an error sentence or null. */
export function validateBankAccount(f: { bank_code: string; account_ref: string }): string | null {
  if (!f.bank_code) return "Pick the bank.";
  const ref = normalizeAccountRef(f.account_ref);
  if (ref && !/^\d{3,12}$/.test(ref)) return "Enter the last 3–12 digits of the account number, as the bank's alerts show them.";
  return null;
}

/** A typed balance as the decimal string record_balance takes: commas dropped, "−" read as "-". Null when invalid. */
export function normalizeBalance(v: string): string | null {
  const s = v.replace(/,/g, "").replace(/−/g, "-").replace(/\s/g, "").replace(/^AED/i, "");
  return /^-?\d{1,12}(\.\d{1,2})?$/.test(s) ? s : null;
}

/**
 * The as-of timestamp for a balance dated `date` (YYYY-MM-DD): null (the server's now) for today
 * or no date, the end of that day in Dubai for an earlier one. Undefined for a future or invalid date.
 */
export function balanceAsOf(date: string, today: ISODate = todayDubai()): string | null | undefined {
  if (!date || date === today) return null;
  if (!isISODate(date) || date > today) return undefined;
  return `${date}T23:59:59+04:00`;
}
