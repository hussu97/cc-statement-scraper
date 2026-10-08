// Display geometry for the overview "pace rule": where each server-provided
// amount sits on a shared horizontal scale. Display only — no money maths.
import { toAmount, type MoneyInput } from "./money";

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

/** Separate labels that would overlap: returns a vertical lane (0, 1, …) per mark. */
export function labelLanes(positions: (number | null)[], minGap = 0.18): number[] {
  const order = positions.map((p, i) => ({ p, i })).filter((x) => x.p !== null).sort((a, b) => (a.p as number) - (b.p as number));
  const lanes = positions.map(() => 0);
  const lastInLane: number[] = [];
  for (const { p, i } of order) {
    let lane = 0;
    while (lastInLane[lane] !== undefined && (p as number) - lastInLane[lane]! < minGap) lane++;
    lanes[i] = lane;
    lastInLane[lane] = p as number;
  }
  return lanes;
}
