// Pure geometry for the hand-rolled SVG ring (WEB-53): Overview draws one donut, which
// isn't worth the chart library's chunk.

/** One arc, as fractions of the circumference measured clockwise from 12 o'clock. */
export interface RingSegment {
  start: number;
  length: number;
}

/** Default gap between neighbouring arcs: 1.5°, as the Recharts donut had. */
export const RING_GAP = 1.5 / 360;

/**
 * Arcs for `values`, in order, each sized by its share of the sum. Zero, negative and
 * non-finite values get an empty arc. Neighbours are separated by `gap` (never more than
 * half a small arc, so no arc vanishes); a single arc closes the ring with no gap.
 */
export function ringSegments(values: number[], gap = RING_GAP): RingSegment[] {
  const clean = values.map((v) => (Number.isFinite(v) && v > 0 ? v : 0));
  const sum = clean.reduce((s, v) => s + v, 0);
  const drawn = clean.filter((v) => v > 0).length;
  let at = 0;
  return clean.map((v) => {
    if (sum === 0 || v === 0) return { start: at, length: 0 };
    const share = v / sum;
    const g = drawn > 1 ? Math.min(gap, share / 2) : 0;
    const seg = { start: at + g / 2, length: share - g };
    at += share;
    return seg;
  });
}

/** `stroke-dasharray` / `stroke-dashoffset` that draw `seg` on a circle of `circumference` (starting at the stroke's origin). */
export function ringDash(seg: RingSegment, circumference: number): { dasharray: string; dashoffset: number } {
  const len = seg.length * circumference;
  return { dasharray: `${len} ${circumference - len}`, dashoffset: -seg.start * circumference };
}
