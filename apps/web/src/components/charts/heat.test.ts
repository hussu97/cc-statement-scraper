import { describe, expect, it } from "vitest";
import { buildCalendar, heatLevel, hourMatrix, isoWeekday, quantileThresholds } from "./heat";
import { categoryVar, heatFill, seriesFill, seriesToken } from "./palette";

describe("quantileThresholds", () => {
  it("ignores zero and invalid values", () => {
    expect(quantileThresholds([0, 0, Number.NaN])).toEqual([]);
  });
  it("spreads cut points across the sorted positive values", () => {
    expect(quantileThresholds([10, 20, 30, 40, 0, 0, 50, 60, 70, 80], 4)).toEqual([30, 50, 70]);
  });
  it("handles a single value", () => {
    expect(quantileThresholds([5], 4)).toEqual([5, 5, 5]);
  });
});

describe("heatLevel", () => {
  const t = [30, 50, 70];
  it("is 0 for nothing spent", () => {
    expect(heatLevel(0, t)).toBe(0);
    expect(heatLevel(-5, t)).toBe(0);
  });
  it("maps values onto 1..levels", () => {
    expect(heatLevel(10, t)).toBe(1);
    expect(heatLevel(30, t)).toBe(2);
    expect(heatLevel(55, t)).toBe(3);
    expect(heatLevel(1000, t)).toBe(4);
  });
  it("puts every positive value at the top when all are equal", () => {
    expect(heatLevel(5, quantileThresholds([5]))).toBe(4);
  });
});

describe("isoWeekday", () => {
  it("numbers Monday 1 to Sunday 7", () => {
    expect(isoWeekday("2026-10-05")).toBe(1);
    expect(isoWeekday("2026-10-11")).toBe(7);
  });
});

describe("buildCalendar", () => {
  it("lays out Monday-first weeks with nulls outside the range", () => {
    const data = new Map([["2026-10-01", { amount: 5 }]]);
    const { weeks, months } = buildCalendar("2026-10-01", "2026-10-12", data);
    expect(weeks).toHaveLength(3);
    expect(weeks[0]!.start).toBe("2026-09-28");
    expect(weeks[0]!.cells.slice(0, 3)).toEqual([null, null, null]); // Mon–Wed before the range
    expect(weeks[0]!.cells[3]).toEqual({ date: "2026-10-01", row: 3, datum: { amount: 5 } });
    expect(weeks[2]!.cells[0]?.date).toBe("2026-10-12");
    expect(weeks[2]!.cells[1]).toBeNull();
    expect(months).toEqual([{ week: 0, label: "Oct" }]);
  });
  it("labels each month once at its first column", () => {
    const { months } = buildCalendar("2026-09-20", "2026-11-03", new Map());
    expect(months.map((m) => m.label)).toEqual(["Sep", "Oct", "Nov"]);
    expect(months[0]!.week).toBe(0);
  });
  it("returns nothing for an inverted range", () => {
    expect(buildCalendar("2026-10-05", "2026-10-01", new Map()).weeks).toEqual([]);
  });
});

describe("hourMatrix", () => {
  it("places rows by isodow and hour, ignoring out-of-range values", () => {
    const m = hourMatrix([
      { dow: 1, hour: 0, v: "a" },
      { dow: 7, hour: 23, v: "b" },
      { dow: 8, hour: 1, v: "x" },
    ]);
    expect(m).toHaveLength(7);
    expect(m[0]![0]?.v).toBe("a");
    expect(m[6]![23]?.v).toBe("b");
    expect(m.flat().filter(Boolean)).toHaveLength(2);
  });
});

describe("palette", () => {
  it("maps category tokens to chart variables", () => {
    expect(categoryVar("cat-3")).toBe("var(--chart-cat-3)");
    expect(categoryVar(null)).toBe("var(--chart-uncategorized)");
    expect(categoryVar("red")).toBe("var(--chart-uncategorized)");
  });
  it("keeps category colours and cycles others by rank", () => {
    expect(seriesToken({ key: "cat_a", colorToken: "cat-7", index: 0, byCategory: true })).toBe("cat-7");
    expect(seriesToken({ key: "mer_a", colorToken: null, index: 0, byCategory: false })).toBe("cat-1");
    expect(seriesToken({ key: "mer_b", colorToken: null, index: 12, byCategory: false })).toBe("cat-13");
    expect(seriesToken({ key: "mer_c", colorToken: null, index: 16, byCategory: false })).toBe("cat-1");
    expect(seriesToken({ key: "__other", colorToken: null, index: 6, byCategory: false })).toBeNull();
    expect(seriesFill(null)).toBe("var(--chart-uncategorized)");
    expect(seriesFill(null, "__other")).toBe("var(--chart-axis)");
  });
  it("mixes accent into the surface by level", () => {
    expect(heatFill(0)).toBe("var(--color-surface-2)");
    expect(heatFill(2, 4)).toBe("color-mix(in oklab, var(--color-accent) 50%, var(--color-surface-2))");
    expect(heatFill(9, 4)).toContain("100%");
  });
});
