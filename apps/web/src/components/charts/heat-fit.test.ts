import { describe, expect, it } from "vitest";
import { calendarEnd, DAY_LABEL_W, fitCalendar, MONTH_LABEL_W } from "./heat";

describe("calendarEnd (WEB-15)", () => {
  it("stops at today when the range runs into the future", () => {
    expect(calendarEnd("2026-10-31", "2026-10-08")).toBe("2026-10-08");
  });
  it("keeps a past range end", () => {
    expect(calendarEnd("2026-09-30", "2026-10-08")).toBe("2026-09-30");
  });
});

describe("fitCalendar", () => {
  it("fills a wide desktop card, capped at 30px", () => {
    expect(fitCalendar(1100, 27)).toEqual({ orientation: "horizontal", size: 30, gap: 4 });
  });
  it("scales cells to the container instead of a fixed size (WEB-15)", () => {
    const f = fitCalendar(900, 53);
    expect(f).toEqual({ orientation: "horizontal", size: 13, gap: 3 });
    expect(DAY_LABEL_W + 53 * (f.size + f.gap)).toBeLessThanOrEqual(900);
  });
  it("keeps a short range horizontal on a phone", () => {
    expect(fitCalendar(300, 5)).toEqual({ orientation: "horizontal", size: 30, gap: 4 });
  });
  it("turns a long range vertical on a phone, with near tap-size cells (WEB-22r)", () => {
    const f = fitCalendar(303, 27);
    expect(f.orientation).toBe("vertical");
    expect(f.size).toBe(34);
    expect(MONTH_LABEL_W + 7 * (f.size + f.gap)).toBeLessThanOrEqual(303);
  });
  it("uses a tablet card's width horizontally", () => {
    expect(fitCalendar(664, 27)).toEqual({ orientation: "horizontal", size: 20, gap: 3 });
  });
  it("never turns vertical on a wide screen; scrolls at the minimum size instead", () => {
    expect(fitCalendar(700, 105)).toEqual({ orientation: "horizontal", size: 11, gap: 3 });
  });
  it("survives a zero width (before the first measure)", () => {
    expect(fitCalendar(0, 27).size).toBeGreaterThan(0);
  });
});
