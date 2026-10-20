// Search-param codecs for screens with tabs and date ranges.
import { isISODate, matchPreset, presetRange, RANGE_PRESETS, type DateRange, type ISODate, type RangePreset } from "./dates";
import { parseTrendFilterSearch, serializeTrendFilters, type TrendFilters, type TrendFilterSearch } from "./trend-filters";

export function parseTabSearch(raw: Record<string, unknown>): { tab?: string } {
  return typeof raw.tab === "string" && /^[a-z-]{1,24}$/.test(raw.tab) ? { tab: raw.tab } : {};
}

// Trends view options (spend_series grouping and bucket size).
// "bank" is monthly only (spend_breakdown); the Trends tab forces month buckets for it.
export const SPEND_GROUPS = ["none", "category", "bank", "merchant", "account", "card"] as const;
export type SpendGroup = (typeof SPEND_GROUPS)[number];
export const GRAINS = ["day", "week", "month"] as const;
export type Grain = (typeof GRAINS)[number];
export const DEFAULT_TREND_GROUP: SpendGroup = "category";

/** A date range in the URL: a preset, or a custom from/to (which wins). */
export interface RangeSearch {
  range?: RangePreset;
  from?: ISODate;
  to?: ISODate;
}

/** Parse an untrusted range: a known preset, or a valid from ≤ to (which drops the preset). */
export function parseRangeSearch(raw: Record<string, unknown>): RangeSearch {
  if (isISODate(raw.from) && isISODate(raw.to) && raw.from <= raw.to) return { from: raw.from, to: raw.to };
  if (typeof raw.range === "string" && RANGE_PRESETS.some((p) => p.value === raw.range)) return { range: raw.range as RangePreset };
  return {};
}

/** Replace a range-only search's range (the category view's URL). */
export function withRange(r: { range: RangePreset } | { from: ISODate; to: ISODate }): RangeSearch {
  return parseRangeSearch(r);
}

/** Trends filters (?cat=&bank=&card=&q=) are in TrendFilterSearch (see trend-filters.ts). */
export interface InsightsSearch extends TrendFilterSearch, RangeSearch {
  tab?: string;
  /** Trends grouping; omitted when it is the default ("category"). */
  group?: SpendGroup;
  /** Trends bucket size; omitted to follow the range (see defaultGrain). */
  grain?: Grain;
}

export function parseInsightsSearch(raw: Record<string, unknown>): InsightsSearch {
  const out: InsightsSearch = { ...parseTabSearch(raw), ...parseRangeSearch(raw) };
  if (typeof raw.group === "string" && (SPEND_GROUPS as readonly string[]).includes(raw.group) && raw.group !== DEFAULT_TREND_GROUP) {
    out.group = raw.group as SpendGroup;
  }
  if (typeof raw.grain === "string" && (GRAINS as readonly string[]).includes(raw.grain)) out.grain = raw.grain as Grain;
  return { ...out, ...parseTrendFilterSearch(raw) };
}

/** Every key parseInsightsSearch may return. */
const INSIGHTS_SEARCH_KEYS = ["tab", "range", "from", "to", "group", "grain", "cat", "bank", "card", "q", "inst"] as const;

/**
 * The Insights route's validateSearch. TanStack Router lays a route's validated search over the raw
 * URL, so a key the parser drops (`?range=junk`, `?inst=cash`) would survive with its raw value and
 * reach the page: every key is returned, the dropped ones as undefined (lessons: TanStack Router).
 */
export function insightsRouteSearch(raw: Record<string, unknown>): InsightsSearch {
  const blank = Object.fromEntries(INSIGHTS_SEARCH_KEYS.map((k) => [k, undefined])) as InsightsSearch;
  return { ...blank, ...parseInsightsSearch(raw) };
}

/** Replace the date range, keeping the tab and Trends options. */
export function withInsightsRange(s: InsightsSearch, r: { range: RangePreset } | { from: ISODate; to: ISODate }): InsightsSearch {
  const { range: _range, from: _from, to: _to, ...rest } = s;
  return parseInsightsSearch({ ...rest, ...r });
}

/** Change the Trends grouping / bucket size; defaults drop out of the URL. */
export function withTrends(s: InsightsSearch, patch: { group?: SpendGroup; grain?: Grain }): InsightsSearch {
  return parseInsightsSearch({ ...s, ...patch });
}

/** Replace the Trends filters, keeping everything else. */
export function withTrendFilters(s: InsightsSearch, f: TrendFilters): InsightsSearch {
  const { cat: _cat, bank: _bank, card: _card, q: _q, inst: _inst, ...rest } = s;
  return parseInsightsSearch({ ...rest, ...serializeTrendFilters(f) });
}

export const DEFAULT_INSIGHTS_RANGE: RangePreset = "last_6_months";

/** Resolve the effective date range for an Insights URL. */
export function insightsRange(s: RangeSearch, today?: ISODate): DateRange & { preset: RangePreset | null } {
  if (s.from && s.to) return { from: s.from, to: s.to, preset: matchPreset({ from: s.from, to: s.to }, today) };
  const preset = s.range ?? DEFAULT_INSIGHTS_RANGE;
  return { ...presetRange(preset, today), preset };
}
