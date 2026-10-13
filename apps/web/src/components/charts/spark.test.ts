import { describe, expect, it } from "vitest";
import { barRatios, labelEvery, sparkLine } from "./spark";

describe("barRatios", () => {
  it("scales to the tallest bar", () => {
    expect(barRatios([50, 100, 25])).toEqual([0.5, 1, 0.25]);
  });

  it("keeps a small non-zero bar visible and a zero bar empty", () => {
    expect(barRatios([1000, 1, 0])).toEqual([1, 0.02, 0]);
    expect(barRatios([1000, 1], 0.05)).toEqual([1, 0.05]);
  });

  it("treats negative and non-finite values as zero", () => {
    expect(barRatios([-10, Number.NaN, 20, Number.POSITIVE_INFINITY])).toEqual([0, 0, 1, 0]);
  });

  it("returns all zeros when nothing was spent, and nothing for no bars", () => {
    expect(barRatios([0, 0])).toEqual([0, 0]);
    expect(barRatios([])).toEqual([]);
  });
});

describe("labelEvery", () => {
  const shown = (count: number, max: number) => Array.from({ length: count }, (_, i) => i).filter(labelEvery(count, max));

  it("shows every label when they fit", () => {
    expect(shown(6, 12)).toEqual([0, 1, 2, 3, 4, 5]);
  });

  it("thins labels evenly and always keeps the latest", () => {
    expect(shown(24, 12)).toEqual([1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23]);
    expect(shown(13, 6)).toEqual([0, 3, 6, 9, 12]);
  });
});

describe("sparkLine", () => {
  it("spaces points evenly and scales the values' range to the box (y down)", () => {
    expect(sparkLine([0, 5, 10], 104, 24)).toEqual({ line: "M2 22 L52 12 L102 2", last: { x: 102, y: 2 } });
  });

  it("widens the domain to the given min and max", () => {
    // Utilisation on a fixed 0–1 scale: 50% sits halfway up.
    expect(sparkLine([0.5, 0.5], 104, 24, { min: 0, max: 1 }).line).toBe("M2 12 L102 12");
  });

  it("puts a flat series in the middle", () => {
    expect(sparkLine([7, 7, 7], 104, 24).line).toBe("M2 12 L52 12 L102 12");
  });

  it("breaks the line at gaps and keeps a lone point visible", () => {
    const g = sparkLine([0, null, 10, 0], 64, 24, { pad: 0 });
    expect(g.line).toBe("M0 24 h0.01 M42.67 0 L64 24");
    expect(g.last).toEqual({ x: 64, y: 24 });
  });

  it("draws nothing without a value", () => {
    expect(sparkLine([], 100, 20)).toEqual({ line: "", last: null });
    expect(sparkLine([null, Number.NaN], 100, 20)).toEqual({ line: "", last: null });
  });

  it("centres a single value", () => {
    expect(sparkLine([3], 100, 20).line).toBe("M50 10 h0.01");
  });
});
