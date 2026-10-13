// URL <-> filter codec for the Activity screen. Pure, so it is unit-tested.
import { isISODate, type ISODate } from "./dates";
import { DEFAULT_PAGE_SIZE, normalizePage, normalizePageSize, type PageSize } from "./pagination";

/**
 * The status filter's values. Neither `pending` (an SMS or payment charge no statement has matched
 * yet) nor `posted` is one: those charges are transactions like any other, and "Posted" would hide
 * them. An old `?status=pending` or `?status=posted` link parses to no status filter.
 */
export const TXN_STATUSES = ["void", "orphaned"] as const;
export type TxnStatus = (typeof TXN_STATUSES)[number];
export const TXN_SOURCES = ["sms", "statement", "both"] as const;
export type TxnSource = (typeof TXN_SOURCES)[number];
/** Category filter value meaning "no category". */
export const UNCATEGORIZED = "none";
/** The keys that narrow the list; also the bulk RPCs' `p_filter` keys (private.activity_selection). */
const FILTER_KEYS = ["from", "to", "account", "card", "category", "status", "source", "q"] as const;

/**
 * The search box keeps its own text while typing and writes `?q=` after a
 * debounce. When `?q=` changes for another reason ("Clear filters", Back), the
 * box must follow (WEB-08). Returns the text to show, or null to keep typing.
 */
export function syncSearchText(urlQ: string | undefined, lastWritten: string | undefined): string | null {
  return (urlQ ?? undefined) === (lastWritten ?? undefined) ? null : (urlQ ?? "");
}

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

const ACTIVITY_SEARCH_KEYS = [...FILTER_KEYS, "txn", "page", "size"] as const;

/**
 * The Activity route's `validateSearch`. TanStack Router lays a route's validated search over its
 * parents' (the root passes the raw URL through), so a key the codec drops would survive from the
 * raw URL: an old `?status=pending` link kept filtering. Every key is therefore present, set to
 * undefined when the codec dropped it, which overrides the raw value.
 */
export function activityRouteSearch(raw: Record<string, unknown>): ActivitySearch {
  const blank = Object.fromEntries(ACTIVITY_SEARCH_KEYS.map((k) => [k, undefined])) as ActivitySearch;
  return { ...blank, ...parseActivitySearch(raw) };
}

/** Filters that narrow the result set (excludes paging). */
export function activeFilterCount(s: ActivitySearch): number {
  return FILTER_KEYS.filter((k) => s[k] !== undefined).length;
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

/**
 * Clean a search term for PostgREST's `or=(…)` filter, exactly as iOS
 * `ActivityQuery.sanitizedSearch` and SQL `private.activity_search_pattern` do:
 * trimmed, first 80 characters, `, ( ) * : "` become the one-character
 * wildcard `_`, and `\ % _` are escaped.
 */
export function sanitizedSearch(raw: string): string {
  let out = "";
  for (const ch of Array.from(raw.trim()).slice(0, 80)) {
    if (",()*:\"".includes(ch)) out += "_";
    else if (ch === "%" || ch === "_" || ch === "\\") out += `\\${ch}`;
    else out += ch;
  }
  return out;
}

/** The Activity search as a PostgREST `or` filter: description OR merchant name. Null when blank. */
export function searchOrFilter(q: string | undefined): string | null {
  const term = sanitizedSearch(q ?? "");
  return term ? `description.ilike.*${term}*,merchant_name.ilike.*${term}*` : null;
}

export type ActivityFilter = Partial<Record<(typeof FILTER_KEYS)[number], string>>;

/**
 * The Activity filters as the bulk RPCs' `p_filter` ("select all matching"): the URL's
 * filter keys only (no paging, no drawer), blank search dropped. Pure.
 */
export function activityFilter(s: ActivitySearch): ActivityFilter {
  const out: ActivityFilter = {};
  for (const k of FILTER_KEYS) {
    const v = s[k];
    if (v === undefined) continue;
    if (k === "q" && !String(v).trim()) continue;
    out[k] = String(v);
  }
  return out;
}

/** The part of the search that determines the list (drops the drawer param). */
export function listSearch(s: ActivitySearch): ActivitySearch {
  const { txn: _txn, ...rest } = s;
  return rest;
}
