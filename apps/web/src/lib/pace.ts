// Display geometry for the overview "pace rule": where each server-provided
// amount sits on a shared horizontal scale, and the labels around it. Display
// only — no money maths: every amount is a server field (CLAUDE.md §2.2).
import { formatMoney, toAmount, type MoneyInput } from "./money";
import { formatDate, type ISODate } from "./dates";

export interface PaceMark {
  key: string;
  value: MoneyInput;
}

export interface PlacedMark {
  key: string;
  /** 0–1 position along the rule; null when the value is missing. */
  at: number | null;
}

/** Place marks on a scale whose end is 8% beyond the largest value. */
export function placeMarks(marks: PaceMark[], headroom = 1.08): { scaleMax: number; marks: PlacedMark[] } {
  const nums = marks.map((m) => toAmount(m.value)).filter((n): n is number => n !== null && n > 0);
  const scaleMax = nums.length ? Math.max(...nums) * headroom : 0;
  return {
    scaleMax,
    marks: marks.map((m) => {
      const n = toAmount(m.value);
      return { key: m.key, at: n === null || scaleMax === 0 ? null : Math.max(0, Math.min(1, n / scaleMax)) };
    }),
  };
}

/** Past the middle a pin's label hangs to the left of its pin, toward the side with more room. */
export const PIN_FLIP_AT = 0.5;

/** The span a label of `width` covers along the rule, given which side of its pin it hangs. */
export function labelSpan(at: number, width: number): [number, number] {
  return at > PIN_FLIP_AT ? [at - width, at] : [at, at + width];
}

/**
 * Separate labels that would overlap: returns a vertical lane (0, 1, …) per mark. Each label
 * covers `width` of the rule on the side it hangs (labelSpan), so a left-hanging label and a
 * right-hanging one that meet in the middle are separated too.
 */
export function labelLanes(positions: (number | null)[], width = 0.18): number[] {
  const order = positions.map((p, i) => ({ p, i })).filter((x): x is { p: number; i: number } => x.p !== null).sort((a, b) => a.p - b.p);
  const lanes = positions.map(() => 0);
  const spans: [number, number][][] = [];
  for (const { p, i } of order) {
    const [from, to] = labelSpan(p, width);
    let lane = 0;
    while (spans[lane]?.some(([a, b]) => from < b && a < to)) lane++;
    lanes[i] = lane;
    (spans[lane] ??= []).push([from, to]);
  }
  return lanes;
}

/** The overview fields the pace rule reads. */
export interface PaceSource {
  spend_prev_month_to_date: MoneyInput;
  spend_avg_3m: MoneyInput;
  /** Previous 3 months up to the same day of the month (server, WEB-26); absent from an older server. */
  spend_avg_3m_to_date?: MoneyInput;
}

export interface PacePin {
  key: "prev" | "avg";
  label: string;
  value: MoneyInput;
}

/**
 * The pins month-to-date spend is set against (WEB-26): last month by today, and the 3-month
 * average by today. Both are month-to-date figures from the server, so the comparison is fair on
 * any day. A server without `spend_avg_3m_to_date` gets its full-month average, labelled as such.
 */
export function pacePins(o: PaceSource, dayLabel: string): PacePin[] {
  const toDate = o.spend_avg_3m_to_date;
  return [
    { key: "prev", label: `Last month by ${dayLabel}`, value: o.spend_prev_month_to_date },
    toAmount(toDate) !== null
      ? { key: "avg", label: `3-month average by ${dayLabel}`, value: toDate }
      : { key: "avg", label: "3-month average, whole month", value: o.spend_avg_3m },
  ];
}

/** "Projected AED 12,346 by 31 Oct" from the server's projected_month_end; null without one. */
export function projectionLabel(projected: MoneyInput, lastDay: ISODate): string | null {
  if (toAmount(projected) === null) return null;
  return `Projected ${formatMoney(projected, { whole: true })} by ${formatDate(lastDay, "short")}`;
}
