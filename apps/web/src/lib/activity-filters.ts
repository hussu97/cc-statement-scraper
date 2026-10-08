// URL <-> filter codec for the Activity screen. Pure, so it is unit-tested.
import { isISODate, type ISODate } from "./dates";
import { DEFAULT_PAGE_SIZE, normalizePage, normalizePageSize, type PageSize } from "./pagination";

export const TXN_STATUSES = ["pending", "posted", "void", "orphaned"] as const;
export type TxnStatus = (typeof TXN_STATUSES)[number];
export const TXN_SOURCES = ["sms", "statement", "both"] as const;
export type TxnSource = (typeof TXN_SOURCES)[number];
/** Category filter value meaning "no category". */
export const UNCATEGORIZED = "none";

export interface ActivitySearch {
  from?: ISODate;
  to?: ISODate;
  account?: string;
  card?: string;
  category?: string;
  status?: TxnStatus;
  source?: TxnSource;
  q?: string;
  page?: number;
  size?: PageSize;
  /** Open transaction drawer (deep link); not a filter. */
  txn?: string;
}

const CODE_RE = (prefix: string) => new RegExp(`^${prefix}_[0-9a-z]{26}$`);
const ACC_RE = CODE_RE("acc");
const CRD_RE = CODE_RE("crd");
const CAT_RE = CODE_RE("cat");
const TXN_RE = CODE_RE("txn");

function str(v: unknown): string | undefined {
  if (typeof v === "number") return String(v);
  return typeof v === "string" && v.trim() !== "" ? v.trim() : undefined;
}

/** Parse untrusted search params. Invalid values are dropped, defaults omitted. */
export function parseActivitySearch(raw: Record<string, unknown>): ActivitySearch {
  const out: ActivitySearch = {};
  const from = str(raw.from);
  const to = str(raw.to);
  if (from && isISODate(from)) out.from = from;
  if (to && isISODate(to)) out.to = to;
  if (out.from && out.to && out.from > out.to) {
    const f = out.from;
    out.from = out.to;
    out.to = f;
  }
  const account = str(raw.account);
  if (account && ACC_RE.test(account)) out.account = account;
  const card = str(raw.card);
  if (card && CRD_RE.test(card)) out.card = card;
  const category = str(raw.category);
  if (category && (category === UNCATEGORIZED || CAT_RE.test(category))) out.category = category;
  const status = str(raw.status);
  if (status && (TXN_STATUSES as readonly string[]).includes(status)) out.status = status as TxnStatus;
  const source = str(raw.source);
  if (source && (TXN_SOURCES as readonly string[]).includes(source)) out.source = source as TxnSource;
  const q = str(raw.q);
  if (q) out.q = q.slice(0, 120);
  const txn = str(raw.txn);
  if (txn && TXN_RE.test(txn)) out.txn = txn;
  const page = normalizePage(raw.page);
  if (page > 1) out.page = page;
  const size = normalizePageSize(raw.size);
  if (size !== DEFAULT_PAGE_SIZE) out.size = size;
  return out;
}

/** Filters that narrow the result set (excludes paging). */
export function activeFilterCount(s: ActivitySearch): number {
  return (["from", "to", "account", "card", "category", "status", "source", "q"] as const).filter((k) => s[k] !== undefined).length;
}

/** Apply a filter change: any filter change resets to page 1. */
export function withFilter(s: ActivitySearch, patch: Partial<ActivitySearch>): ActivitySearch {
  const next: ActivitySearch = { ...s, ...patch };
  if (!("page" in patch)) delete next.page;
  for (const k of Object.keys(next) as (keyof ActivitySearch)[]) {
    if (next[k] === undefined || next[k] === "") delete next[k];
  }
  return parseActivitySearch(next as Record<string, unknown>);
}

/** Escape a user search term for a PostgREST ilike pattern. */
export function ilikePattern(q: string): string {
  return `%${q.replace(/[\\%_]/g, (c) => `\\${c}`).replace(/[,()]/g, " ")}%`;
}

/** The part of the search that determines the list (drops the drawer param). */
export function listSearch(s: ActivitySearch): ActivitySearch {
  const { txn: _txn, ...rest } = s;
  return rest;
}
