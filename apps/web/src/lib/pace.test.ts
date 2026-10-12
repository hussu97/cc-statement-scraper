import { describe, expect, it } from "vitest";
import { labelLanes, labelSpan, pacePins, PIN_FLIP_AT, placeMarks, projectionLabel } from "./pace";

describe("pacePins (WEB-26)", () => {
  const base = { spend_prev_month_to_date: "2100.00", spend_avg_3m: "9865.00" };

  it("sets spend against the 3-month average by today, not the full-month average", () => {
    const pins = pacePins({ ...base, spend_avg_3m_to_date: "3120.50" }, "the 13th");
    expect(pins).toEqual([
      { key: "prev", label: "Last month by the 13th", value: "2100.00" },
      { key: "avg", label: "3-month average by the 13th", value: "3120.50" },
    ]);
  });

  it("keeps a to-date average of zero (an early day with no history)", () => {
    expect(pacePins({ ...base, spend_avg_3m_to_date: "0.00" }, "the 1st")[1]).toEqual({
      key: "avg",
      label: "3-month average by the 1st",
      value: "0.00",
    });
  });

  it("falls back to the full-month average, labelled as such, from a server without the field", () => {
    expect(pacePins(base, "the 13th")[1]).toEqual({ key: "avg", label: "3-month average, whole month", value: "9865.00" });
    expect(pacePins({ ...base, spend_avg_3m_to_date: "" }, "the 13th")[1]!.value).toBe("9865.00");
  });

  it("passes the server's strings through untouched", () => {
    const pins = pacePins({ ...base, spend_avg_3m_to_date: "3120.55" }, "the 13th");
    expect(pins.map((p) => p.value)).toEqual(["2100.00", "3120.55"]);
  });

  it("places spend and both pins on one scale", () => {
    const pins = pacePins({ ...base, spend_avg_3m_to_date: "1000.00" }, "the 8th");
    const { marks } = placeMarks([{ key: "spend", value: "860.00" }, ...pins]);
    expect(marks.map((m) => m.key)).toEqual(["spend", "prev", "avg"]);
    // the largest value (2100) sits at 1 / 1.08 of the rule, the others in proportion
    expect(marks[1]!.at).toBeCloseTo(1 / 1.08);
    expect(marks[0]!.at).toBeCloseTo(860 / (2100 * 1.08));
  });
});

describe("labelLanes", () => {
  it("separates a right-hanging and a left-hanging label that meet in the middle", () => {
    // 0.3 hangs right to 0.7; 0.8 hangs left from 0.4: they overlap although 0.5 apart
    expect(labelLanes([0.3, 0.8], 0.4)).toEqual([0, 1]);
  });

  it("separates two left-hanging labels (the 13 Oct overview: pins at 0.59 and 0.92)", () => {
    expect(labelLanes([0.59, 0.92], 0.5)).toEqual([0, 1]);
  });

  it("keeps labels on one lane when their spans do not touch", () => {
    expect(labelLanes([0.1, 0.95], 0.4)).toEqual([0, 0]);
    expect(labelSpan(0.1, 0.4)).toEqual([0.1, 0.5]);
    expect(labelSpan(0.95, 0.4)[0]).toBeCloseTo(0.55);
  });

  it("hangs labels past PIN_FLIP_AT to the left", () => {
    expect(labelSpan(PIN_FLIP_AT + 0.1, 0.2)[1]).toBeCloseTo(PIN_FLIP_AT + 0.1);
    expect(labelSpan(PIN_FLIP_AT, 0.2)[0]).toBe(PIN_FLIP_AT);
  });
});

describe("projectionLabel (WEB-26)", () => {
  it("says where the month is heading, by its last day", () => {
    expect(projectionLabel("12345.60", "2026-10-31")).toBe("Projected AED 12,346 by 31 Oct");
  });

  it("names a short month's own last day", () => {
    expect(projectionLabel("800.00", "2027-02-28")).toBe("Projected AED 800 by 28 Feb");
    expect(projectionLabel("800.00", "2026-09-30")).toBe("Projected AED 800 by 30 Sep");
  });

  it("is null without a projection (a future month, or an older server)", () => {
    expect(projectionLabel(null, "2026-10-31")).toBeNull();
    expect(projectionLabel(undefined, "2026-10-31")).toBeNull();
    expect(projectionLabel("", "2026-10-31")).toBeNull();
  });

  it("shows a zero projection rather than hiding it", () => {
    expect(projectionLabel("0.00", "2026-10-31")).toBe("Projected AED 0 by 31 Oct");
  });
});
