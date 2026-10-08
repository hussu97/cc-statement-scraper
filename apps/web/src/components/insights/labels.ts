// Pure display helpers for the Insights screen.
import { daysBetween, formatDate, formatMonth, type ISODate } from "@/lib/dates";
import { formatCount, toAmount, type MoneyInput } from "@/lib/money";
import type { Grain } from "@/data/analytics";
import { MONTH_SHORT, shortMonth } from "@/components/charts/heat";

export const INSIGHT_TABS = [
  { value: "trends", label: "Trends" },
  { value: "categories", label: "Categories" },
  { value: "merchants", label: "Merchants" },
  { value: "subscriptions", label: "Subscriptions" },
  { value: "fx", label: "FX & travel" },
  { value: "calendar", label: "Calendar" },
  { value: "time", label: "Time of day" },
  { value: "yoy", label: "Year over year" },
  { value: "anomalies", label: "Anomalies" },
] as const;
export type InsightTab = (typeof INSIGHT_TABS)[number]["value"];

/** Resolve a URL `tab` value to a known tab (default: trends). */
export function resolveTab(tab: string | undefined): InsightTab {
  return INSIGHT_TABS.some((t) => t.value === tab) ? (tab as InsightTab) : "trends";
}

/**
 * Tone for a server change fraction (e.g. category_breakdown.change, 0.12 = +12%):
 * spending more than before is a warning; spending less is good news.
 */
export function changeTone(change: MoneyInput): "warn" | "positive" | "neutral" {
  const f = toAmount(change);
  if (f === null || f === 0) return "neutral";
  return f > 0 ? "warn" : "positive";
}

const ANOMALY_REASONS: Record<string, string> = {
  merchant_outlier: "Unusual for this merchant",
  category_outlier: "Unusual for this category",
  new_merchant_large: "Large first purchase",
};
export function anomalyReasonLabel(reason: string | null | undefined): string {
  return (reason && ANOMALY_REASONS[reason]) || "Unusual";
}

const CADENCES: Record<string, string> = { weekly: "Weekly", monthly: "Monthly", yearly: "Yearly" };
export function cadenceLabel(cadence: string | null | undefined): string {
  return (cadence && CADENCES[cadence]) || "—";
}

/**
 * Badge for a subscription's price change (server ratio, e.g. 0.12 = +12%).
 * Changes under half a percent are noise and get no badge.
 */
export function priceChangeBadge(ratio: MoneyInput): { label: string; tone: "warn" | "positive" } | null {
  const r = toAmount(ratio);
  if (r === null || Math.abs(r) < 0.005) return null;
  const pct = Math.round(Math.abs(r) * 100);
  return r > 0 ? { label: `+${pct || "<1"}%`, tone: "warn" } : { label: `−${pct || "<1"}%`, tone: "positive" };
}

/** X-axis / tooltip label for a spend_series bucket. */
export function bucketLabel(bucket: string, grain: Grain, long = false): string {
  if (grain === "month") return long ? formatMonth(bucket) : shortMonth(bucket);
  if (grain === "week") return long ? `Week of ${formatDate(bucket, "short")}` : formatDate(bucket, "short");
  return long ? formatDate(bucket, "day") : formatDate(bucket, "short");
}

/** Years offered by the year-over-year selector, newest first. */
/**
 * Recharts `interval` for a category axis: show every label when they fit
 * (`maxLabels`), else every Nth, evenly. Replaces `minTickGap`, which dropped
 * arbitrary months ("May", "Aug") on a 6-bar chart at 390 px (WEB-18).
 */
export function axisTickInterval(count: number, maxLabels: number): number {
  if (count <= maxLabels || maxLabels < 1) return 0;
  return Math.ceil(count / maxLabels) - 1;
}

export function yearOptions(currentYear: number, count = 6): number[] {
  return Array.from({ length: count }, (_, i) => currentYear - i);
}

export { MONTH_SHORT };

/** Whether every value in a server series is zero (proves an empty chart). */
export function allZero(values: MoneyInput[]): boolean {
  return values.every((v) => (toAmount(v) ?? 0) === 0);
}

/** Range description: "1 May – 31 Oct 2026". */
export function rangeLabel(from: ISODate, to: ISODate): string {
  const sameYear = from.slice(0, 4) === to.slice(0, 4);
  return `${sameYear ? formatDate(from, "short") : formatDate(from)} – ${formatDate(to)}`;
}

/** A sensible bucket size for a range: days for a month, weeks for a quarter. */
export function defaultGrain(from: ISODate, to: ISODate): Grain {
  const days = daysBetween(from, to) + 1;
  if (days <= 45) return "day";
  if (days <= 120) return "week";
  return "month";
}

/** "1 transaction" / "12 transactions". */
export function countLabel(n: number | null | undefined, noun: string, plural = `${noun}s`): string {
  const v = n ?? 0;
  return `${formatCount(v)} ${v === 1 ? noun : plural}`;
}
