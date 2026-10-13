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

/** Which bar labels to show: every one when they fit in `maxLabels`, else every Nth, always keeping the last. */
export function labelEvery(count: number, maxLabels: number): (index: number) => boolean {
  if (count <= maxLabels || maxLabels < 1) return () => true;
  const step = Math.ceil(count / maxLabels);
  return (i) => (count - 1 - i) % step === 0;
}
