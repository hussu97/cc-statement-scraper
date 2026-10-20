// URL <-> filter codec for the Insights "Spending over time" card. Pure, so it is unit-tested.
//
// ?cat=&bank=&card= hold comma-separated codes (codes never contain commas), so a
// link stays readable and the router keeps them as plain strings; ?q= is the
// merchant / description search; ?inst=credit|debit narrows to one kind of card (Phase 2c,
// p_instruments). AND across filter types, OR within one — the
// server applies them (spend_series / spend_breakdown, private.filtered_spend).

/** Category filter value meaning "no category" (spend_breakdown's key for it). */
export const UNCATEGORIZED_KEY = "__uncategorized__";

/** The URL form: each list is a comma-joined string, omitted when empty. */
export interface TrendFilterSearch {
  cat?: string;
  bank?: string;
  card?: string;
  q?: string;
  inst?: "credit" | "debit";
}

/** v_spend.instrument: what kind of card paid. */
export type Instrument = "credit_card" | "debit_card";
const INST_FROM_URL: Record<string, Instrument> = { credit: "credit_card", debit: "debit_card" };
const INST_TO_URL: Record<Instrument, "credit" | "debit"> = { credit_card: "credit", debit_card: "debit" };

/** The parsed form the hooks and UI work with. Lists are deduped, in URL order. */
export interface TrendFilters {
  categories: string[];
  banks: string[];
  cards: string[];
  q?: string;
  /** Unset: credit and debit cards both. */
  instrument?: Instrument;
}

export const NO_TREND_FILTERS: TrendFilters = { categories: [], banks: [], cards: [] };

const CAT_RE = /^cat_[0-9a-z]{26}$/;
const CRD_RE = /^crd_[0-9a-z]{26}$/;
const BANK_RE = /^[A-Z]{2,10}$/; // public.banks CHECK
/** More than this many values in one list is not a real selection; extras are dropped. */
const MAX_CODES = 50;
const MAX_Q = 120;

const isCategory = (v: string) => v === UNCATEGORIZED_KEY || CAT_RE.test(v);

/** Untrusted list param (comma-joined string, or an array) to valid, deduped codes. */
function codeList(raw: unknown, valid: (v: string) => boolean): string[] {
  const parts = Array.isArray(raw) ? raw : typeof raw === "string" ? raw.split(",") : [];
  const out: string[] = [];
  for (const p of parts) {
    if (typeof p !== "string") continue;
    const v = p.trim();
    if (valid(v) && !out.includes(v)) out.push(v);
    if (out.length === MAX_CODES) break;
  }
  return out;
}

/** Parse untrusted search params into the URL form. Invalid values are dropped. */
export function parseTrendFilterSearch(raw: Record<string, unknown>): TrendFilterSearch {
  return serializeTrendFilters({
    categories: codeList(raw.cat, isCategory),
    banks: codeList(raw.bank, (v) => BANK_RE.test(v)),
    cards: codeList(raw.card, (v) => CRD_RE.test(v)),
    q: typeof raw.q === "string" ? raw.q : typeof raw.q === "number" ? String(raw.q) : undefined,
    instrument: typeof raw.inst === "string" ? INST_FROM_URL[raw.inst] : undefined,
  });
}

/** URL form to filters. */
export function trendFilters(s: TrendFilterSearch): TrendFilters {
  const f: TrendFilters = {
    categories: codeList(s.cat, isCategory),
    banks: codeList(s.bank, (v) => BANK_RE.test(v)),
    cards: codeList(s.card, (v) => CRD_RE.test(v)),
  };
  const q = s.q?.trim();
  if (q) f.q = q.slice(0, MAX_Q);
  const instrument = s.inst ? INST_FROM_URL[s.inst] : undefined;
  if (instrument) f.instrument = instrument;
  return f;
}

/** Filters to the URL form; empty lists and a blank search drop out. */
export function serializeTrendFilters(f: TrendFilters): TrendFilterSearch {
  const out: TrendFilterSearch = {};
  if (f.categories.length) out.cat = f.categories.join(",");
  if (f.banks.length) out.bank = f.banks.join(",");
  if (f.cards.length) out.card = f.cards.join(",");
  const q = f.q?.trim();
  if (q) out.q = q.slice(0, MAX_Q);
  if (f.instrument) out.inst = INST_TO_URL[f.instrument];
  return out;
}

/** How many filters narrow the chart (each selected value counts, the search counts once). */
export function trendFilterCount(f: TrendFilters): number {
  return f.categories.length + f.banks.length + f.cards.length + (f.q ? 1 : 0) + (f.instrument ? 1 : 0);
}

/** Add `value` to a list, or remove it if present. */
export function toggleCode(list: readonly string[], value: string): string[] {
  return list.includes(value) ? list.filter((v) => v !== value) : [...list, value];
}
