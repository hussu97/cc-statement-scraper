// Business dates are calendar dates in Asia/Dubai. Date-only values travel as
// "YYYY-MM-DD" strings; arithmetic on them is done in UTC so it never shifts.

export const TIMEZONE = "Asia/Dubai";
export type ISODate = string; // YYYY-MM-DD

const ISO_RE = /^\d{4}-\d{2}-\d{2}$/;

export function isISODate(v: unknown): v is ISODate {
  if (typeof v !== "string" || !ISO_RE.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

/** Today's calendar date in Dubai. */
export function todayDubai(now: Date = new Date()): ISODate {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: TIMEZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

function toUTC(d: ISODate): Date {
  return new Date(`${d}T00:00:00Z`);
}
function fromUTC(d: Date): ISODate {
  return d.toISOString().slice(0, 10);
}

export function addDays(d: ISODate, n: number): ISODate {
  const x = toUTC(d);
  x.setUTCDate(x.getUTCDate() + n);
  return fromUTC(x);
}

export function monthStart(d: ISODate): ISODate {
  return `${d.slice(0, 7)}-01`;
}

export function addMonths(d: ISODate, n: number): ISODate {
  const x = toUTC(monthStart(d));
  x.setUTCMonth(x.getUTCMonth() + n);
  return fromUTC(x);
}

export function monthEnd(d: ISODate): ISODate {
  return addDays(addMonths(d, 1), -1);
}

export function daysBetween(a: ISODate, b: ISODate): number {
  return Math.round((toUTC(b).getTime() - toUTC(a).getTime()) / 86_400_000);
}

const fmtCache = new Map<string, Intl.DateTimeFormat>();
function fmt(key: string, opts: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  let f = fmtCache.get(key);
  if (!f) {
    f = new Intl.DateTimeFormat("en-GB", opts);
    fmtCache.set(key, f);
  }
  return f;
}

const MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** "8 Oct 2026" (or "8 Oct" when `short`). Date-only values are not shifted. */
export function formatDate(d: ISODate | null | undefined, style: "short" | "long" | "day" = "long"): string {
  if (!d) return "—";
  const x = toUTC(d.slice(0, 10));
  if (Number.isNaN(x.getTime())) return "—";
  const dm = `${x.getUTCDate()} ${MONTHS_SHORT[x.getUTCMonth()]}`;
  if (style === "day") return `${WEEKDAYS_SHORT[x.getUTCDay()]} ${dm}`;
  if (style === "short") return dm;
  return `${dm} ${x.getUTCFullYear()}`;
}

/** "1 Jun 2026 – 8 Oct 2026", one date when both ends agree, null when there are none. */
export function formatDateSpan(from: ISODate | null | undefined, to: ISODate | null | undefined): string | null {
  if (!from && !to) return null;
  if (!from || !to || from === to) return formatDate(from ?? to);
  return `${formatDate(from)} – ${formatDate(to)}`;
}

export function formatMonth(d: ISODate | null | undefined, style: "long" | "short" = "long"): string {
  if (!d) return "—";
  const x = toUTC(monthStart(d.slice(0, 10)));
  return style === "long"
    ? fmt("month-long", { timeZone: "UTC", month: "long", year: "numeric" }).format(x)
    : fmt("month-short", { timeZone: "UTC", month: "short" }).format(x);
}

/** A timestamp shown in Dubai time: "8 Oct, 14:22". */
export function formatDateTime(ts: string | null | undefined): string {
  if (!ts) return "—";
  const x = new Date(ts);
  if (Number.isNaN(x.getTime())) return "—";
  return `${formatDate(todayDubai(x), "short")}, ${formatTime(ts)}`;
}

export function formatTime(ts: string | null | undefined): string {
  if (!ts) return "";
  const x = new Date(ts);
  if (Number.isNaN(x.getTime())) return "";
  return fmt("time", { timeZone: TIMEZONE, hour: "2-digit", minute: "2-digit", hour12: false }).format(x);
}

/** "3 min ago" / "2 h ago" / "5 d ago" relative to now. */
export function formatRelative(ts: string | null | undefined, now: Date = new Date()): string {
  if (!ts) return "never";
  const t = new Date(ts).getTime();
  if (Number.isNaN(t)) return "—";
  const s = Math.round((now.getTime() - t) / 1000);
  if (s < 45) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 36) return `${h} h ago`;
  const d = Math.round(h / 24);
  if (d < 60) return `${d} d ago`;
  return formatDate(new Date(t).toISOString().slice(0, 10));
}

export interface DateRange {
  from: ISODate;
  to: ISODate;
}

export type RangePreset = "this_month" | "last_month" | "last_3_months" | "last_6_months" | "ytd" | "last_12_months";

export const RANGE_PRESETS: { value: RangePreset; label: string }[] = [
  { value: "this_month", label: "This month" },
  { value: "last_month", label: "Last month" },
  { value: "last_3_months", label: "Last 3 months" },
  { value: "last_6_months", label: "Last 6 months" },
  { value: "ytd", label: "Year to date" },
  { value: "last_12_months", label: "Last 12 months" },
];

export function presetRange(preset: RangePreset, today: ISODate = todayDubai()): DateRange {
  const m = monthStart(today);
  switch (preset) {
    case "this_month":
      return { from: m, to: monthEnd(m) };
    case "last_month":
      return { from: addMonths(m, -1), to: addDays(m, -1) };
    case "last_3_months":
      return { from: addMonths(m, -2), to: monthEnd(m) };
    case "last_6_months":
      return { from: addMonths(m, -5), to: monthEnd(m) };
    case "ytd":
      return { from: `${today.slice(0, 4)}-01-01`, to: today };
    case "last_12_months":
      return { from: addMonths(m, -11), to: monthEnd(m) };
  }
}

export function matchPreset(range: DateRange, today: ISODate = todayDubai()): RangePreset | null {
  for (const p of RANGE_PRESETS) {
    const r = presetRange(p.value, today);
    if (r.from === range.from && r.to === range.to) return p.value;
  }
  return null;
}

export const WEEKDAYS_ISO = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;
