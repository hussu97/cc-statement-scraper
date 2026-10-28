import { describe, expect, it } from "vitest";
import { couponLine, gapText, isCreditVerdict, monthYear, nextCheckLine, shareBars, verdictDate, verdictLine, type NoteShare } from "./note-verdict";

const TODAY = "2026-10-27";

describe("verdictLine", () => {
  it("words each kind with its tone", () => {
    expect(verdictLine({ kind: "on_track", date: "2027-03-15" }, TODAY)).toEqual({ text: "On track to be called on 15 Mar", tone: "positive" });
    expect(verdictLine({ kind: "needs", symbol: "GOOGL", gap_pct: "9.33", date: "2027-03-15" }, TODAY)).toEqual({
      text: "Called on 15 Mar if GOOGL rises 9.3%",
      tone: "neutral",
    });
    expect(verdictLine({ kind: "needs", symbol: "ORCL", gap_pct: "38.88", date: "2026-12-22" }, TODAY)).toEqual({
      text: "Called on 22 Dec if ORCL rises 38.9%",
      tone: "warn",
    });
    expect(verdictLine({ kind: "coupon_at_risk", symbol: "GOOGL", gap_pct: "0.30", date: "2026-11-23", call_gap_pct: "7.46", call_date: "2027-04-22" }, TODAY)).toEqual({
      text: "Coupon at risk: GOOGL is 0.3% below the barrier (check 23 Nov)",
      tone: "warn",
    });
    expect(verdictLine({ kind: "to_maturity", symbol: "JPM", gap_pct: "-9.60", date: "2028-06-20" }, TODAY)).toEqual({
      text: "Runs to Jun 2028 · capital safe while JPM stays above its break-even",
      tone: "neutral",
    });
    expect(verdictLine({ kind: "to_maturity", symbol: "JPM", gap_pct: "4.2", date: "2028-06-20" }, TODAY)).toEqual({
      text: "Runs to Jun 2028 · JPM is 4.2% below break-even",
      tone: "danger",
    });
    expect(verdictLine({ kind: "awaiting_prices" }, TODAY)?.text).toBe("Waiting for today's prices");
    expect(verdictLine({ kind: "ended" }, TODAY)?.text).toBe("Ended");
  });

  it("reads a met 'needs' as on track", () => {
    expect(verdictLine({ kind: "needs", symbol: "META", gap_pct: "0", date: "2027-03-15" }, TODAY)?.tone).toBe("positive");
  });

  it("shows nothing for an unknown kind or no verdict", () => {
    expect(verdictLine({ kind: "something_new" }, TODAY)).toBeNull();
  });
  it("words a credit-linked note in one line, in its currency", () => {
    // broker_portfolio's two Example Bank N CLNs (local stack, 28 Oct 2026).
    expect(verdictLine({ date: "2026-11-20", kind: "cln_paying", amount: "87.50", rate_pct: "10.5", maturity_date: "2031-12-20" }, TODAY, "USD")).toEqual({
      text: "Paying 10.5% a year · next coupon USD 87.50 on 20 Nov",
      tone: "positive",
    });
    expect(verdictLine({ date: "2026-12-20", kind: "cln_accruing", amount: "3168.96", rate_pct: "13.25", call_date: "2026-12-20", maturity_date: "2034-12-20" }, TODAY, "USD")).toEqual({
      text: "13.25% a year, building up · USD 3,168.96 accrued",
      tone: "neutral",
    });
    expect(verdictLine({ kind: "cln_paying", rate_pct: "10.5" }, TODAY, "USD")?.text).toBe("Paying 10.5% a year");
    expect(isCreditVerdict({ kind: "cln_accruing" })).toBe(true);
    expect(isCreditVerdict({ kind: "on_track" })).toBe(false);
    expect(isCreditVerdict(null)).toBe(false);
    expect(verdictLine(null, TODAY)).toBeNull();
  });

  it("puts the year on a date more than ~10 months away", () => {
    expect(verdictDate("2027-03-15", TODAY)).toBe("15 Mar");
    expect(verdictDate("2028-03-15", TODAY)).toBe("15 Mar 2028");
    expect(monthYear("2028-06-20")).toBe("Jun 2028");
    expect(monthYear("2026-09-01")).toBe("Sep 2026");
    expect(monthYear(null)).toBe("—");
    expect(gapText("-9.60")).toBe("9.6%");
    expect(gapText(null)).toBe("—");
  });
});

describe("the next check", () => {
  it("says when, how soon and what calls it", () => {
    expect(nextCheckLine({ obs_date: "2027-03-15", days: 139, is_final: false, autocall: { trigger_pct: "100" } })).toBe(
      "Next check 15 Mar 2027 · in 139 days · called if every stock is at or above 100% of its start",
    );
    expect(nextCheckLine({ obs_date: "2026-11-23", days: 1, is_final: false, coupon: { barrier_pct: "98", amount: "146.74" } })).toBe(
      "Next check 23 Nov 2026 · in 1 day · coupon paid if every stock is at or above 98% of its start",
    );
    expect(nextCheckLine({ obs_date: "2028-06-20", days: 602, is_final: true })).toBe("Final check 20 Jun 2028 · in 602 days");
    expect(nextCheckLine({ obs_date: "2026-11-23", days: 27, is_final: false, coupon: { barrier_pct: "98" } }, false)).toBe("Next check 23 Nov 2026 · in 27 days");
    expect(nextCheckLine(null)).toBeNull();
  });
  it("words the coupon at stake", () => {
    expect(couponLine({ obs_date: "2026-11-23", days: 27, is_final: false, coupon: { amount: "146.74", barrier_pct: "98" } }, (v) => `$${v}`)).toBe(
      "Coupon of $146.74 is paid only if every stock is above 98% of its start",
    );
    expect(couponLine({ obs_date: "2026-11-23", days: 27, is_final: false }, (v) => v)).toBeNull();
  });
});

// Shaped like the server's underlyings (the Example Bank M note, rounded).
const NOTE_M: NoteShare[] = [
  { symbol: "AMZN", initial: "250.38", close: "249.09", perf_pct: "99.48", is_worst: false, autocall_level: "262.9", coupon_level: "245.37", break_even_level: "247.88", to_autocall_pct: "5.54", to_coupon_pct: "-1.49", to_break_even_pct: "-0.49" },
  { symbol: "GOOGL", initial: "324.22", close: "316.8", perf_pct: "97.71", is_worst: true, autocall_level: "340.43", coupon_level: "317.74", break_even_level: "320.98", to_autocall_pct: "7.46", to_coupon_pct: "0.30", to_break_even_pct: "1.32" },
  { symbol: "MSFT", initial: "500", close: "530", perf_pct: "106", is_worst: false, autocall_level: "525", coupon_level: "490", break_even_level: "495", to_autocall_pct: "-0.94", to_coupon_pct: "-7.5", to_break_even_pct: "-6.6" },
];

describe("shareBars", () => {
  it("puts the stock holding the note back first, then by level", () => {
    expect(shareBars(NOTE_M).map((b) => b.symbol)).toEqual(["GOOGL", "AMZN", "MSFT"]);
  });

  it("places the barrier, start, close and call in order on a padded bar", () => {
    const g = shareBars(NOTE_M)[0]!;
    expect(g.barrierKind).toBe("coupon");
    expect(g.barrierAt!).toBeGreaterThan(0);
    expect(g.dotAt).toBeLessThan(g.barrierAt!);
    expect(g.startAt).toBeGreaterThan(g.barrierAt!);
    expect(g.callAt!).toBeGreaterThan(g.startAt);
    expect(g.callAt!).toBeLessThan(100);
    expect(g.close).toBe("316.8");
    expect(g.start).toBe("324.22");
  });

  it("colours the dot from the server's distances and words the call", () => {
    const [g, a, m] = shareBars(NOTE_M);
    expect([g!.dotTone, g!.status]).toEqual(["danger", "needs +7.5%"]);
    expect([a!.dotTone, a!.status]).toEqual(["warn", "needs +5.5%"]);
    expect([m!.dotTone, m!.status, m!.statusMet]).toEqual(["positive", "at call level", true]);
  });

  it("uses the break-even when no autocall is left", () => {
    const [b] = shareBars([{ symbol: "JPM", initial: "300", close: "280", break_even_level: "285", to_break_even_pct: "1.8", autocall_level: null, to_autocall_pct: null }]);
    expect(b).toMatchObject({ callAt: null, barrierKind: "break_even", dotTone: "danger", status: "needs +1.8%" });
    const [ok] = shareBars([{ symbol: "AMZN", initial: "227", close: "249", break_even_level: "216", to_break_even_pct: "-13.11" }]);
    expect(ok).toMatchObject({ dotTone: "positive", status: "above break-even", statusMet: true });
  });

  it("skips unpriced shares and tolerates a missing list", () => {
    expect(shareBars([{ symbol: "X", initial: "10", close: null }])).toEqual([]);
    expect(shareBars(undefined)).toEqual([]);
  });
});
