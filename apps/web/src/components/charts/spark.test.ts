import { describe, expect, it } from "vitest";
import { barRatios, labelEvery } from "./spark";

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
