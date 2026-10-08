// Search-param codecs for screens with tabs and date ranges.
import { isISODate, matchPreset, presetRange, RANGE_PRESETS, type DateRange, type ISODate, type RangePreset } from "./dates";

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

export interface InsightsSearch {
  tab?: string;
  range?: RangePreset;
  from?: ISODate;
  to?: ISODate;
  /** Trends grouping; omitted when it is the default ("category"). */
  group?: SpendGroup;
  /** Trends bucket size; omitted to follow the range (see defaultGrain). */
  grain?: Grain;
}

export function parseInsightsSearch(raw: Record<string, unknown>): InsightsSearch {
  const out: InsightsSearch = { ...parseTabSearch(raw) };
  if (typeof raw.range === "string" && RANGE_PRESETS.some((p) => p.value === raw.range)) out.range = raw.range as RangePreset;
  if (isISODate(raw.from) && isISODate(raw.to) && raw.from <= raw.to) {
    out.from = raw.from;
    out.to = raw.to;
    delete out.range;
  }
  if (typeof raw.group === "string" && (SPEND_GROUPS as readonly string[]).includes(raw.group) && raw.group !== DEFAULT_TREND_GROUP) {
    out.group = raw.group as SpendGroup;
  }
  if (typeof raw.grain === "string" && (GRAINS as readonly string[]).includes(raw.grain)) out.grain = raw.grain as Grain;
  return out;
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

export const DEFAULT_INSIGHTS_RANGE: RangePreset = "last_6_months";

/** Resolve the effective date range for an Insights URL. */
export function insightsRange(s: InsightsSearch, today?: ISODate): DateRange & { preset: RangePreset | null } {
  if (s.from && s.to) return { from: s.from, to: s.to, preset: matchPreset({ from: s.from, to: s.to }, today) };
  const preset = s.range ?? DEFAULT_INSIGHTS_RANGE;
  return { ...presetRange(preset, today), preset };
}
