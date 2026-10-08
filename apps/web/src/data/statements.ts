import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { displayRatio, toAmount, type MoneyInput } from "@/lib/money";
import { keys } from "./keys";
import { must } from "./api";

/** Money crosses the wire as a decimal string (CLAUDE.md §1.3). */
type Decimal = string;

/** One current statement line (statement_detail). */
export interface StatementLine {
  line_code: string;
  /** Null while the line is not part of a transaction (e.g. held in Review). */
  txn_code: string | null;
  txn_date: string;
  posting_date: string | null;
  /** The line as the statement printed it. */
  description: string;
  /** From the linked transaction's merchant; null when there is none. */
  merchant_name: string | null;
  amount_aed: Decimal | null;
  amount_original: Decimal;
  currency_original: string;
  /** The linked transaction's effective category. */
  category_code: string | null;
  kind: string;
  card_last4: string | null;
}

export interface StatementSide {
  count: number;
  total: Decimal;
  lines: StatementLine[];
}

export interface StatementHeader {
  stmt_code: string;
  kind: string;
  bank_code: string;
  account_code: string;
  card_last4s: string[];
  statement_date: string;
  period_start: string | null;
  period_end: string | null;
  due_date: string | null;
  opening_balance: Decimal | null;
  closing_balance: Decimal | null;
  total_debits: Decimal | null;
  total_credits: Decimal | null;
  min_due: Decimal | null;
  credit_limit: Decimal | null;
  /** Not sent today; used as soon as the server adds it (see utilisationOf). */
  utilisation?: Decimal | null;
  doc_code: string | null;
  recon_status: string | null;
  recon_checks: Record<string, unknown> | null;
}

/** statement_detail(p_profile_code, p_stmt_code). Generated types say Json; this is its shape (ARCHITECTURE §6). */
export interface StatementDetail {
  statement: StatementHeader;
  debits: StatementSide;
  credits: StatementSide;
}

const STMT_RE = /^stm_[0-9a-z]{26}$/;

/** Whether a URL segment is a statement code worth asking the server about. Pure. */
export function isStatementCode(v: unknown): v is string {
  return typeof v === "string" && STMT_RE.test(v);
}

export function useStatementDetail(profileCode: string, stmtCode: string) {
  return useQuery({
    queryKey: keys.statement(profileCode, stmtCode),
    enabled: isStatementCode(stmtCode),
    // P0002 (unknown statement) and 42501 (not a member) are answers, not glitches.
    retry: (n, e) => n < 2 && !["P0002", "42501"].includes((e as { code?: string }).code ?? ""),
    queryFn: async () =>
      must(await supabase.rpc("statement_detail", { p_profile_code: profileCode, p_stmt_code: stmtCode })) as unknown as StatementDetail,
  });
}

/**
 * Utilisation for the tile: the server's figure when it sends one; until
 * then, a display-only ratio of two server values (closing / limit), like a
 * progress bar width. Null without a limit. Pure, unit-tested.
 */
export function utilisationOf(s: Pick<StatementHeader, "utilisation" | "closing_balance" | "credit_limit">): number | null {
  const server = toAmount(s.utilisation);
  if (server !== null) return server;
  const r = displayRatio(s.closing_balance, s.credit_limit);
  return r === null ? null : Math.max(0, r);
}

/** Meter tone for a utilisation ratio: same thresholds as the cards list. */
export function utilisationTone(u: number | null): "positive" | "warn" | "danger" {
  if (u === null) return "positive";
  return u > 0.7 ? "danger" : u > 0.3 ? "warn" : "positive";
}

/** A line as TxnAmount input: AED with the original foreign amount underneath. */
export function lineAmount(line: StatementLine, side: "debit" | "credit"): { amount_aed: MoneyInput; amount_original: MoneyInput; currency_original: string; direction: "debit" | "credit" } {
  return { amount_aed: line.amount_aed, amount_original: line.amount_original, currency_original: line.currency_original, direction: side };
}

/** Title for a line: the merchant when the transaction has one, else the printed description. */
export function lineTitle(line: Pick<StatementLine, "merchant_name" | "description">): string {
  return line.merchant_name?.trim() || line.description;
}

/** Days from `today` to the due date (negative when past), or null. Pure. */
export function dueInDays(due: string | null, today: string): number | null {
  if (!due) return null;
  const a = Date.parse(`${today}T00:00:00Z`);
  const b = Date.parse(`${due.slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(a) || Number.isNaN(b)) return null;
  return Math.round((b - a) / 86_400_000);
}
