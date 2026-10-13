import { describe, expect, it } from "vitest";
import { dueBadge, dueLabel, paidNote, paymentStatusOf } from "./dues";

describe("dueLabel", () => {
  it("says today and tomorrow in words", () => {
    expect(dueLabel(0)).toBe("Due today");
    expect(dueLabel(1)).toBe("Due tomorrow");
  });
  it("counts days after that", () => {
    expect(dueLabel(2)).toBe("Due in 2 days");
    expect(dueLabel(12)).toBe("Due in 12 days");
  });
  it("has nothing to say for a past or missing date", () => {
    expect(dueLabel(-1)).toBeNull();
    expect(dueLabel(null)).toBeNull();
  });
});

describe("paymentStatusOf", () => {
  it("keeps the four server values", () => {
    for (const s of ["paid", "part_paid", "unpaid", "overdue"]) expect(paymentStatusOf(s)).toBe(s);
  });
  it("drops anything else", () => {
    expect(paymentStatusOf(null)).toBeNull();
    expect(paymentStatusOf(undefined)).toBeNull();
    expect(paymentStatusOf("PAID")).toBeNull();
  });
});

describe("dueBadge", () => {
  it("shows the server's settled states whatever the date", () => {
    expect(dueBadge("paid", -20)).toEqual({ label: "Paid", tone: "positive" });
    expect(dueBadge("paid", 3)).toEqual({ label: "Paid", tone: "positive" });
    expect(dueBadge("part_paid", 3)).toEqual({ label: "Part paid", tone: "warn" });
    expect(dueBadge("overdue", -1)).toEqual({ label: "Overdue", tone: "danger" });
  });
  it("counts down an unpaid due inside a week", () => {
    expect(dueBadge("unpaid", 0)).toEqual({ label: "Due today", tone: "danger" });
    expect(dueBadge("unpaid", 1)).toEqual({ label: "Due tomorrow", tone: "danger" });
    expect(dueBadge("unpaid", 2)).toEqual({ label: "Due in 2 days", tone: "danger" });
    expect(dueBadge("unpaid", 7)).toEqual({ label: "Due in 7 days", tone: "warn" });
  });
  it("stays quiet for a due further out", () => {
    expect(dueBadge("unpaid", 8)).toBeNull();
    expect(dueBadge("unpaid", null)).toBeNull();
  });
  it("never calls a past due overdue or paid without the server", () => {
    expect(dueBadge(null, -3)).toBeNull();
    expect(dueBadge(undefined, -1)).toBeNull();
  });
  it("still counts down when an older server sends no status", () => {
    expect(dueBadge(undefined, 0)).toEqual({ label: "Due today", tone: "danger" });
  });
});

describe("paidNote", () => {
  it("shows how much of a part-paid or overdue statement was paid", () => {
    expect(paidNote("part_paid", "1510.82")).toBe("AED 1,511 paid");
    expect(paidNote("overdue", "25.00")).toBe("AED 25 paid");
  });
  it("stays quiet when there is nothing to add", () => {
    expect(paidNote("overdue", "0.00")).toBeNull();
    expect(paidNote("paid", "2000.00")).toBeNull();
    expect(paidNote("unpaid", "0.00")).toBeNull();
    expect(paidNote("part_paid", null)).toBeNull();
    expect(paidNote(undefined, "10.00")).toBeNull();
  });
});
