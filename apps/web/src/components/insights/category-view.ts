// Pure helpers for the category view (/insights/category/$categoryCode, MA-1).
import { UNCATEGORIZED, type ActivitySearch } from "@/lib/activity-filters";
import { UNCATEGORIZED_KEY } from "@/lib/trend-filters";
import { addMonths, monthStart, type DateRange } from "@/lib/dates";
import { BREAKDOWN_OTHER_KEY, type SpendBreakdownGroup } from "@/data/analytics";

const CAT_RE = /^cat_[0-9a-z]{26}$/;

/** A category code in the URL: a category, or "none" for uncategorised spend (as Activity's ?category=). */
export function isCategoryParam(v: string | null | undefined): v is string {
  return typeof v === "string" && (v === UNCATEGORIZED || CAT_RE.test(v));
}

/** The URL code for a category_breakdown / overview row (null = uncategorised). */
export function categoryParam(code: string | null | undefined): string {
  return code ?? UNCATEGORIZED;
}

/** The spend RPCs' category filter value for a URL code ("none" is "__uncategorized__" there). */
export function categoryFilterKey(param: string): string {
  return param === UNCATEGORIZED ? UNCATEGORIZED_KEY : param;
}

/** The category_breakdown row for a URL code; null when the category had no spend in the range. */
export function breakdownRowFor<T extends { category_code: string | null }>(rows: T[], param: string): T | null {
  return rows.find((r) => categoryParam(r.category_code) === param) ?? null;
}

/** spend_breakdown merchant keys that are not one merchant. */
const NOT_A_MERCHANT = new Set([BREAKDOWN_OTHER_KEY, "__unknown__"]);

/**
 * Activity search for one of the category's top merchants: the category, the range and the
 * merchant's name as the search. Null for "Others" and the unknown-merchant bucket.
 */
export function merchantActivitySearch(group: Pick<SpendBreakdownGroup, "key" | "label">, param: string, range: DateRange): ActivitySearch | null {
  const name = group.label.trim();
  if (NOT_A_MERCHANT.has(group.key) || !name) return null;
  return { category: param, from: range.from, to: range.to, q: name.slice(0, 120) };
}

/** The fewest months the category's trend shows, so "This month" still has history to compare with. */
export const TREND_MIN_MONTHS = 6;

/**
 * The trend's range: the selected range, widened back to at least `minMonths` whole months
 * ending with the range's last month. The totals, change and merchants keep the selected range.
 */
export function trendRange(range: DateRange, minMonths = TREND_MIN_MONTHS): DateRange {
  const earliest = addMonths(monthStart(range.to), -(Math.max(1, minMonths) - 1));
  return { from: range.from < earliest ? range.from : earliest, to: range.to };
}
