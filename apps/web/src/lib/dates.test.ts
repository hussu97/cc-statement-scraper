import { describe, expect, it } from "vitest";
import { addDays, addMonths, daysBetween, formatDate, formatDateSpan, formatDateTime, formatMonth, formatRelative, isISODate, matchPreset, monthEnd, monthStart, presetRange, todayDubai } from "./dates";

describe("dates", () => {
  it("formats a date span", () => {
    expect(formatDateSpan("2026-06-01", "2026-10-08")).toBe("1 Jun 2026 – 8 Oct 2026");
    expect(formatDateSpan("2026-10-08", "2026-10-08")).toBe("8 Oct 2026");
    expect(formatDateSpan(null, "2026-10-08")).toBe("8 Oct 2026");
    expect(formatDateSpan(null, null)).toBeNull();
  });

  it("computes today in Dubai, not UTC", () => {
    // 21:30 UTC on 8 Oct is 01:30 on 9 Oct in Dubai (UTC+4).
    expect(todayDubai(new Date("2026-10-08T21:30:00Z"))).toBe("2026-10-09");
    expect(todayDubai(new Date("2026-10-08T10:00:00Z"))).toBe("2026-10-08");
  });

  it("validates ISO dates", () => {
    expect(isISODate("2026-02-28")).toBe(true);
    expect(isISODate("2026-02-30")).toBe(false);
    expect(isISODate("2026-2-3")).toBe(false);
    expect(isISODate(20260101)).toBe(false);
  });

  it("does calendar arithmetic without drift", () => {
    expect(addDays("2026-03-01", -1)).toBe("2026-02-28");
    expect(addMonths("2026-01-31", 1)).toBe("2026-02-01");
    expect(monthStart("2026-10-08")).toBe("2026-10-01");
    expect(monthEnd("2026-02-10")).toBe("2026-02-28");
    expect(daysBetween("2026-10-01", "2026-10-08")).toBe(7);
  });

  it("formats", () => {
    expect(formatDate("2026-10-08")).toBe("8 Oct 2026");
    expect(formatDate("2026-10-08", "short")).toBe("8 Oct");
    expect(formatMonth("2026-10-08")).toBe("October 2026");
    expect(formatDateTime("2026-10-08T10:22:00Z")).toBe("8 Oct, 14:22");
    expect(formatDate(null)).toBe("—");
  });

  it("formats relative times", () => {
    const now = new Date("2026-10-08T12:00:00Z");
    expect(formatRelative("2026-10-08T11:59:50Z", now)).toBe("just now");
    expect(formatRelative("2026-10-08T11:30:00Z", now)).toBe("30 min ago");
    expect(formatRelative("2026-10-06T12:00:00Z", now)).toBe("2 d ago");
    expect(formatRelative(null, now)).toBe("never");
  });

  it("builds and recognises presets", () => {
    expect(presetRange("this_month", "2026-10-08")).toEqual({ from: "2026-10-01", to: "2026-10-31" });
    expect(presetRange("last_month", "2026-10-08")).toEqual({ from: "2026-09-01", to: "2026-09-30" });
    expect(presetRange("ytd", "2026-10-08")).toEqual({ from: "2026-01-01", to: "2026-10-08" });
    expect(presetRange("last_12_months", "2026-10-08")).toEqual({ from: "2025-11-01", to: "2026-10-31" });
    expect(matchPreset({ from: "2026-09-01", to: "2026-09-30" }, "2026-10-08")).toBe("last_month");
    expect(matchPreset({ from: "2026-09-02", to: "2026-09-30" }, "2026-10-08")).toBeNull();
  });
});

describe("month abbreviations", () => {
  it("uses three-letter months everywhere", () => {
    expect(formatDate("2026-09-24", "short")).toBe("24 Sep");
    expect(formatDate("2026-09-24", "day")).toBe("Thu 24 Sep");
    expect(formatDateTime("2026-09-23T21:30:00Z")).toBe("24 Sep, 01:30");
  });
});
