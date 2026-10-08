// Search-param codecs for screens with tabs and date ranges.
import { isISODate, matchPreset, presetRange, RANGE_PRESETS, type DateRange, type ISODate, type RangePreset } from "./dates";

export function parseTabSearch(raw: Record<string, unknown>): { tab?: string } {
  return typeof raw.tab === "string" && /^[a-z-]{1,24}$/.test(raw.tab) ? { tab: raw.tab } : {};
}

export interface InsightsSearch {
  tab?: string;
  range?: RangePreset;
  from?: ISODate;
  to?: ISODate;
}

export function parseInsightsSearch(raw: Record<string, unknown>): InsightsSearch {
  const out: InsightsSearch = { ...parseTabSearch(raw) };
  if (typeof raw.range === "string" && RANGE_PRESETS.some((p) => p.value === raw.range)) out.range = raw.range as RangePreset;
  if (isISODate(raw.from) && isISODate(raw.to) && raw.from <= raw.to) {
    out.from = raw.from;
    out.to = raw.to;
    delete out.range;
  }
  return out;
}

export const DEFAULT_INSIGHTS_RANGE: RangePreset = "last_6_months";

/** Resolve the effective date range for an Insights URL. */
export function insightsRange(s: InsightsSearch, today?: ISODate): DateRange & { preset: RangePreset | null } {
  if (s.from && s.to) return { from: s.from, to: s.to, preset: matchPreset({ from: s.from, to: s.to }, today) };
  const preset = s.range ?? DEFAULT_INSIGHTS_RANGE;
  return { ...presetRange(preset, today), preset };
}
