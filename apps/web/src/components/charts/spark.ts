// Pure geometry for the small hand-rolled charts (the category view's month bars, the Cards
// comparison sparklines). Like ring.ts: a few bars or a line aren't worth the chart library's
// chunk. Amounts arrive from the server; these only turn them into drawing positions.

/**
 * Bar heights as fractions (0–1) of the tallest bar. Zero, negative and non-finite values get
 * 0; a non-zero value never drops below `minVisible`, so a small month still shows a sliver.
 */
export function barRatios(values: number[], minVisible = 0.02): number[] {
  const clean = values.map((v) => (Number.isFinite(v) && v > 0 ? v : 0));
  const max = Math.max(0, ...clean);
  if (max === 0) return clean.map(() => 0);
  return clean.map((v) => (v === 0 ? 0 : Math.max(minVisible, v / max)));
}

export interface SparkGeometry {
  /** SVG path for the line; a null value breaks it. "" when nothing is drawable. */
  line: string;
  /** The last drawn point, for an end marker. */
  last: { x: number; y: number } | null;
}

/**
 * A sparkline across a `width` × `height` box (y grows downwards), points evenly spaced. The
 * vertical domain is the values' own range, widened to include `min` / `max` when given (e.g.
 * 0–1 for utilisation, so the height reads as a share of the limit). A flat series sits in the
 * middle. Null and non-finite values are gaps; a lone point between gaps is drawn as a dot-length
 * segment so it stays visible.
 */
export function sparkLine(values: (number | null)[], width: number, height: number, opts: { min?: number; max?: number; pad?: number } = {}): SparkGeometry {
  const pad = opts.pad ?? 2;
  const nums = values.filter((v): v is number => v !== null && Number.isFinite(v));
  if (nums.length === 0) return { line: "", last: null };
  let lo = Math.min(...nums, opts.min ?? Number.POSITIVE_INFINITY);
  let hi = Math.max(...nums, opts.max ?? Number.NEGATIVE_INFINITY);
  if (hi === lo) {
    lo -= 1;
    hi += 1;
  }
  const n = values.length;
  const x = (i: number) => (n === 1 ? width / 2 : pad + (i * (width - 2 * pad)) / (n - 1));
  const y = (v: number) => pad + ((hi - v) / (hi - lo)) * (height - 2 * pad);
  const round = (v: number) => Math.round(v * 100) / 100;
  let line = "";
  let last: SparkGeometry["last"] = null;
  let open = false;
  values.forEach((v, i) => {
    if (v === null || !Number.isFinite(v)) {
      open = false;
      return;
    }
    const px = round(x(i));
    const py = round(y(v));
    const next = values[i + 1];
    const alone = !open && (i === n - 1 || next === null || next === undefined || !Number.isFinite(next));
    line += open ? ` L${px} ${py}` : `${line ? " " : ""}M${px} ${py}${alone ? ` h0.01` : ""}`;
    open = true;
    last = { x: px, y: py };
  });
  return { line, last };
}

/** Which bar labels to show: every one when they fit in `maxLabels`, else every Nth, always keeping the last. */
export function labelEvery(count: number, maxLabels: number): (index: number) => boolean {
  if (count <= maxLabels || maxLabels < 1) return () => true;
  const step = Math.ceil(count / maxLabels);
  return (i) => (count - 1 - i) % step === 0;
}
