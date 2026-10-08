// Pure helpers for heatmaps (calendar and hour × weekday). Amounts here are
// display values only: they decide a cell's shade, never a figure shown.
import { addDays, type ISODate } from "@/lib/dates";

/** Fixed English month abbreviations (Intl's en-GB gives "Sept"). */
export const MONTH_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"] as const;

export function shortMonth(d: ISODate): string {
  return MONTH_SHORT[Number(d.slice(5, 7)) - 1] ?? d.slice(0, 7);
}

/**
 * Quantile cut points over the positive values, so shades spread evenly
 * across the data rather than being dominated by one big day.
 * Returns `levels - 1` ascending thresholds (may repeat for small samples).
 */
export function quantileThresholds(values: number[], levels = 4): number[] {
  const pos = values.filter((v) => Number.isFinite(v) && v > 0).sort((a, b) => a - b);
  if (pos.length === 0) return [];
  const out: number[] = [];
  for (let i = 1; i < levels; i++) {
    const idx = Math.min(pos.length - 1, Math.floor((i / levels) * pos.length));
    out.push(pos[idx]!);
  }
  return out;
}

/** Shade level for a value: 0 for nothing spent, then 1…levels. */
export function heatLevel(value: number, thresholds: number[]): number {
  if (!Number.isFinite(value) || value <= 0) return 0;
  let level = 1;
  for (const t of thresholds) if (value >= t) level++;
  return Math.min(level, thresholds.length + 1);
}

/** ISO weekday, 1 = Monday … 7 = Sunday, for a YYYY-MM-DD date. */
export function isoWeekday(d: ISODate): number {
  const w = new Date(`${d}T00:00:00Z`).getUTCDay();
  return w === 0 ? 7 : w;
}

export interface CalendarCell<T> {
  date: ISODate;
  /** Row 0 = Monday … 6 = Sunday. */
  row: number;
  datum: T | null;
}
export interface CalendarWeek<T> {
  /** Monday of this week. */
  start: ISODate;
  cells: (CalendarCell<T> | null)[];
}
export interface CalendarLayout<T> {
  weeks: CalendarWeek<T>[];
  /** Month labels: the week column where each month first appears. */
  months: { week: number; label: string }[];
}

/**
 * Lay out a dense day range as GitHub-style columns: one column per ISO week,
 * Monday at the top. Days outside [from, to] are null so the grid stays square.
 */
export function buildCalendar<T>(from: ISODate, to: ISODate, byDate: Map<string, T>): CalendarLayout<T> {
  const weeks: CalendarWeek<T>[] = [];
  const months: { week: number; label: string }[] = [];
  if (from > to) return { weeks, months };
  let monday = addDays(from, 1 - isoWeekday(from));
  let lastMonth = "";
  while (monday <= to) {
    const cells: (CalendarCell<T> | null)[] = [];
    for (let row = 0; row < 7; row++) {
      const date = addDays(monday, row);
      if (date < from || date > to) {
        cells.push(null);
        continue;
      }
      const month = date.slice(0, 7);
      if (month !== lastMonth) {
        // Label a month on the column holding its first visible day, unless
        // that column already carries the previous month's label.
        const week = weeks.length;
        if (!months.some((m) => m.week === week)) months.push({ week, label: shortMonth(date) });
        lastMonth = month;
      }
      cells.push({ date, row, datum: byDate.get(date) ?? null });
    }
    weeks.push({ start: monday, cells });
    monday = addDays(monday, 7);
  }
  return { weeks, months };
}

/**
 * Dense 7 × 24 matrix from hour_weekday_pattern rows (isodow 1–7, hour 0–23).
 * Missing cells are null.
 */
export function hourMatrix<T extends { dow: number; hour: number }>(rows: T[]): (T | null)[][] {
  const m: (T | null)[][] = Array.from({ length: 7 }, () => Array.from({ length: 24 }, () => null));
  for (const r of rows) {
    if (r.dow >= 1 && r.dow <= 7 && r.hour >= 0 && r.hour <= 23) m[r.dow - 1]![r.hour] = r;
  }
  return m;
}
