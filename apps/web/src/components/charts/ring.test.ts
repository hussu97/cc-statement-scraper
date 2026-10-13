import { describe, expect, it } from "vitest";
import { RING_GAP, ringDash, ringSegments } from "./ring";

const end = (s: { start: number; length: number }) => s.start + s.length;

describe("ringSegments", () => {
  it("sizes arcs by share, in order, with a gap between neighbours", () => {
    const [a, b, c] = ringSegments([50, 30, 20]);
    expect(a!.start).toBeCloseTo(RING_GAP / 2);
    expect(a!.length).toBeCloseTo(0.5 - RING_GAP);
    expect(b!.start).toBeCloseTo(0.5 + RING_GAP / 2);
    expect(b!.length).toBeCloseTo(0.3 - RING_GAP);
    expect(end(c!)).toBeCloseTo(1 - RING_GAP / 2);
  });

  it("never overlaps and stays inside the circle", () => {
    const segs = ringSegments([900, 1, 0.5, 80, 3]);
    for (let i = 1; i < segs.length; i++) expect(segs[i]!.start).toBeGreaterThanOrEqual(end(segs[i - 1]!));
    expect(segs[0]!.start).toBeGreaterThanOrEqual(0);
    expect(end(segs.at(-1)!)).toBeLessThanOrEqual(1);
  });

  it("keeps a tiny share visible: the gap is capped at half the arc", () => {
    const [, tiny] = ringSegments([999, 1]);
    expect(tiny!.length).toBeCloseTo(0.001 / 2, 6);
    expect(tiny!.length).toBeGreaterThan(0);
  });

  it("closes the ring for a single value", () => {
    expect(ringSegments([42])).toEqual([{ start: 0, length: 1 }]);
    expect(ringSegments([0, 42, 0])[1]).toEqual({ start: 0, length: 1 });
  });

  it("gives zero, negative and non-finite values an empty arc", () => {
    const segs = ringSegments([10, 0, -5, Number.NaN, 10]);
    expect(segs.map((s) => s.length > 0)).toEqual([true, false, false, false, true]);
    expect(ringSegments([])).toEqual([]);
    expect(ringSegments([0, 0])).toEqual([
      { start: 0, length: 0 },
      { start: 0, length: 0 },
    ]);
  });
});

describe("ringDash", () => {
  it("draws the arc's length and skips to its start", () => {
    expect(ringDash({ start: 0.25, length: 0.5 }, 100)).toEqual({ dasharray: "50 50", dashoffset: -25 });
    expect(ringDash({ start: 0, length: 1 }, 100)).toEqual({ dasharray: "100 0", dashoffset: -0 });
  });
});
