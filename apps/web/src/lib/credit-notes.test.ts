import { describe, expect, it } from "vitest";
import type { CreditCoupon, NoteCredit } from "@/data/notes";
import {
  annualisedText,
  callDateRows,
  callNoticeText,
  couponRows,
  couponStatus,
  couponTermsText,
  creditEventText,
  creditVerdict,
  entityLines,
  entityTermsText,
  frequencyText,
  isCreditLinked,
  maturityTermsText,
  scheduleHint,
} from "./credit-notes";
import type { NoteVerdict } from "./note-verdict";

const TODAY = "2026-10-28";

// The two Example Bank N CLNs as structured_note_detail returns them on the local stack (28 Oct 2026),
// the Example Airlines schedule trimmed from 87 rows.
const coupon = (seq: number, period_start: string, pay_date: string, amount: string, status: string, rate_pct = "0.875"): CreditCoupon => ({
  seq,
  period_start,
  pay_date,
  rate_pct,
  amount,
  is_final: seq === 87,
  is_call_date: false,
  status,
});

const AA: NoteCredit & { schedule: CreditCoupon[] } = {
  accrued: { since: "2026-10-20", amount: "23.33" },
  schedule: [
    coupon(1, "2024-10-15", "2024-10-20", "14.58", "paid", "0.145833"),
    coupon(2, "2024-10-20", "2024-11-20", "87.50", "paid"),
    coupon(25, "2026-09-20", "2026-10-20", "87.50", "paid"),
    coupon(26, "2026-10-20", "2026-11-20", "87.50", "to_come"),
    coupon(27, "2026-11-20", "2026-12-20", "87.50", "to_come"),
    coupon(86, "2031-10-20", "2031-11-20", "87.50", "to_come"),
    coupon(87, "2031-11-20", "2031-12-20", "87.50", "to_come"),
  ],
  day_count: "30/360",
  seniority: "Senior",
  call_dates: [],
  to_maturity: { date: "2031-12-20", total: "15439.58", profit: "5389.58", coupons: "5439.58", return_pct: "53.63", annualised_pct: "6.15" },
  credit_event: { kept: "14.58", accrued_lost: "23.33", interest_lost: "5425.00", principal_at_risk: "10000.00" },
  maturity_date: "2031-12-20",
  if_called_next: null,
  next_call_date: null,
  coupon_rate_pct: "10.5",
  call_notice_days: null,
  coupon_frequency: "monthly",
  reference_entity: "Example Airlines Group Inc",
  transaction_type: "Standard North American Corporate",
  first_coupon_date: "2024-10-20",
  remaining_coupons: "5425.00",
  interest_start_date: "2024-10-15",
  interest_at_maturity: false,
  longstop_maturity_date: "2032-12-20",
  reference_obligation_isin: "US0000AA0001",
};
const AA_VERDICT: NoteVerdict = { date: "2026-11-20", kind: "cln_paying", amount: "87.50", rate_pct: "10.5", maturity_date: "2031-12-20" };

const EXM: NoteCredit & { schedule: CreditCoupon[] } = {
  accrued: { since: "2025-02-13", amount: "3168.96" },
  schedule: [{ seq: 1, amount: "18276.90", status: "to_come", is_final: true, pay_date: "2034-12-20", rate_pct: "130.549306", is_call_date: false, period_start: "2025-02-13" }],
  day_count: "30/360",
  seniority: "Senior",
  call_dates: ["2025-12-20", "2026-12-20", "2027-12-20", "2028-12-20", "2029-12-20", "2030-12-20", "2031-12-20", "2032-12-20", "2033-12-20"],
  to_maturity: { date: "2034-12-20", total: "32276.90", profit: "18176.90", coupons: "18276.90", return_pct: "128.91", annualised_pct: "8.81" },
  credit_event: { kept: "0.00", accrued_lost: "3168.96", interest_lost: "18276.90", principal_at_risk: "14000.00" },
  maturity_date: "2034-12-20",
  if_called_next: { date: "2026-12-20", total: "17436.90", profit: "3336.90", return_pct: "23.67", annualised_pct: "12.53" },
  next_call_date: "2026-12-20",
  coupon_rate_pct: "13.25",
  call_notice_days: "10",
  coupon_frequency: "at_maturity",
  reference_entity: "Example Motors Automotive PLC",
  transaction_type: "Standard European Corporate",
  first_coupon_date: null,
  remaining_coupons: "18276.90",
  interest_start_date: "2025-02-13",
  interest_at_maturity: true,
  longstop_maturity_date: "2035-12-20",
  reference_obligation_isin: "XS0000RB0002",
};
const EXM_VERDICT: NoteVerdict = { date: "2026-12-20", kind: "cln_accruing", amount: "3168.96", rate_pct: "13.25", call_date: "2026-12-20", maturity_date: "2034-12-20" };

describe("isCreditLinked", () => {
  it("only a credit_linked note with its credit block", () => {
    expect(isCreditLinked({ note_type: "credit_linked", credit: AA })).toBe(true);
    expect(isCreditLinked({ note_type: "equity", credit: null })).toBe(false);
    expect(isCreditLinked({ credit: undefined })).toBe(false);
    expect(isCreditLinked({ note_type: "credit_linked", credit: null })).toBe(false);
    expect(isCreditLinked(null)).toBe(false);
  });
});

describe("creditVerdict", () => {
  it("coupons on a schedule: the rate, then the next coupon and maturity", () => {
    expect(creditVerdict(AA_VERDICT, AA, "USD", TODAY)).toEqual({
      headline: { text: "Paying 10.5% a year", tone: "positive" },
      lines: ["Next coupon USD 87.50 on 20 Nov 2026 · matures 20 Dec 2031"],
    });
  });
  it("interest paid at maturity: what has built up, when it is paid, and the next call", () => {
    expect(creditVerdict(EXM_VERDICT, EXM, "USD", TODAY)).toEqual({
      headline: { text: "13.25% a year, building up", tone: "neutral" },
      lines: ["USD 3,168.96 accrued so far, paid at maturity (20 Dec 2034) or if the issuer calls it", "If called on 20 Dec 2026: USD 17,436.90 back (+USD 3,336.90)"],
    });
  });
  it("a note the issuer can't call says only maturity", () => {
    const v = creditVerdict({ ...EXM_VERDICT, call_date: null }, { call_dates: [], if_called_next: null }, "USD", TODAY);
    expect(v?.lines).toEqual(["USD 3,168.96 accrued so far, paid at maturity (20 Dec 2034)"]);
  });
  it("nothing for an equity verdict or none", () => {
    expect(creditVerdict({ kind: "on_track", date: "2027-03-15" }, null, "USD", TODAY)).toBeNull();
    expect(creditVerdict(null, AA, "USD", TODAY)).toBeNull();
  });
});

describe("reference entity", () => {
  it("names the entity with its seniority and transaction type", () => {
    expect(entityLines(AA)).toEqual({ entity: "Example Airlines Group Inc", detail: "Senior · Standard North American Corporate" });
    expect(entityLines({ reference_entity: "X", seniority: null, transaction_type: " " })).toEqual({ entity: "X", detail: null });
    expect(entityTermsText(AA)).toBe("Example Airlines Group Inc (Senior, Standard North American Corporate)");
    expect(entityTermsText({ reference_entity: "X", seniority: null, transaction_type: null })).toBe("X");
  });
  it("says what a credit event costs: coupons received are kept", () => {
    expect(creditEventText(AA, "live", "USD")).toBe(
      "If Example Airlines Group Inc has a credit event (default, bankruptcy or restructuring), interest stops and the note repays what the market recovers, possibly far below 100%. " +
        "At risk now: USD 10,000.00 face value and USD 5,425.00 of interest to come; the USD 14.58 already received is kept.",
    );
  });
  it("interest paid at maturity: the accrued interest is lost too, and nothing was received", () => {
    expect(creditEventText(EXM, "live", "USD")).toBe(
      "If Example Motors Automotive PLC has a credit event (default, bankruptcy or restructuring), interest stops and the note repays what the market recovers, possibly far below 100%. " +
        "At risk now: USD 14,000.00 face value and USD 18,276.90 of interest to come, including the USD 3,168.96 accrued so far, since nothing is paid until maturity.",
    );
  });
  it("an ended note: what happened, or nothing", () => {
    expect(creditEventText({ ...AA, credit_event: null }, "credit_event", "USD")).toBe("Example Airlines Group Inc had a credit event: interest stopped and the note repays what the market recovers.");
    expect(creditEventText({ ...AA, credit_event: null }, "matured", "USD")).toBeNull();
  });
});

describe("coupon schedule", () => {
  it("summarises paid, received and to come", () => {
    expect(scheduleHint(AA, "14.58", "USD")).toBe("3 of 7 paid · USD 14.58 received · USD 5,425.00 to come");
    const full = Array.from({ length: 87 }, (_, i) => ({ status: i < 25 ? "paid" : "to_come" }));
    expect(scheduleHint({ ...AA, schedule: full }, "2114.58", "USD")).toBe("25 of 87 paid · USD 2,114.58 received · USD 5,425.00 to come");
    expect(scheduleHint(EXM, "0.00", "USD")).toBe("Paid at maturity · USD 18,276.90 to come");
  });
  it("coupons from before the purchase aren't counted", () => {
    const schedule = [{ status: "before_purchase" }, { status: "paid" }, { status: "to_come" }];
    expect(scheduleHint({ ...AA, schedule, remaining_coupons: "0" }, null, "USD")).toBe("1 of 2 paid");
  });
  it("words each coupon and marks the next", () => {
    const rows = couponRows(AA, "USD");
    expect(rows[0]).toEqual({ seq: 1, date: "20 Oct 2024", description: null, amount: "USD 14.58", status: "Paid", tone: "positive", next: false });
    expect(rows.filter((r) => r.next).map((r) => r.seq)).toEqual([26]);
    expect(couponRows(EXM, "USD")).toEqual([
      { seq: 1, date: "20 Dec 2034", description: "Interest from 13 Feb 2025 at 13.25% a year", amount: "USD 18,276.90", status: "To come", tone: "muted", next: true },
    ]);
  });
  it("statuses in words, an unknown one as its words", () => {
    expect(couponStatus("before_purchase").label).toBe("Before you bought");
    expect(couponStatus("not_paid")).toEqual({ label: "Not paid", tone: "muted" });
    expect(couponStatus("held_back").label).toBe("Held back");
  });
});

describe("issuer call dates", () => {
  it("marks the next and the ones passed", () => {
    const rows = callDateRows(EXM);
    expect(rows).toHaveLength(9);
    expect(rows[0]).toEqual({ date: "2025-12-20", label: "20 Dec 2025", next: false, passed: true });
    expect(rows[1]).toEqual({ date: "2026-12-20", label: "20 Dec 2026", next: true, passed: false });
    expect(rows[8]!.passed).toBe(false);
  });
  it("words the notice", () => {
    expect(callNoticeText("10")).toBe("The issuer may repay at 100% plus accrued interest on these dates, with at least 10 business days' notice.");
    expect(callNoticeText(null)).toBe("The issuer may repay at 100% plus accrued interest on these dates.");
  });
});

describe("terms", () => {
  it("words the coupon", () => {
    expect(couponTermsText(AA)).toBe("10.5% a year, paid monthly, 30/360, from 15 Oct 2024");
    expect(couponTermsText(EXM)).toBe("13.25% a year, paid at maturity or call");
    expect(couponTermsText({ ...EXM, call_dates: [] })).toBe("13.25% a year, paid at maturity");
    expect(couponTermsText({ ...AA, coupon_frequency: "semiannual", day_count: null })).toBe("10.5% a year, paid every six months, from 15 Oct 2024");
  });
  it("words maturity with its longstop", () => {
    expect(maturityTermsText(AA)).toBe("20 Dec 2031; as late as 20 Dec 2032 if a credit event is being determined");
    expect(maturityTermsText({ maturity_date: "2031-12-20", longstop_maturity_date: null })).toBe("20 Dec 2031");
  });
  it("frequencies and the yearly return", () => {
    expect(frequencyText("annual")).toBe("yearly");
    expect(frequencyText("every_two_years")).toBe("every two years");
    expect(annualisedText("6.15")).toBe("6.2% a year");
    expect(annualisedText(null)).toBeNull();
  });
});
