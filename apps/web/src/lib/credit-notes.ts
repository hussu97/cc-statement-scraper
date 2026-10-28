// Credit-linked notes (20261028110553_credit_linked_notes.sql): a fixed coupon on a reference
// entity's credit, no shares. Every figure (schedule, accrued interest, coupons to come, held to
// maturity, if called, what a credit event costs) is private.cln_evaluate's (CLAUDE.md §2.2);
// these helpers only word it and decide which words apply. Pure, unit-tested.
import type { CouponFrequency, CreditCoupon, NoteCredit } from "@/data/notes";
import { formatDate, todayDubai, type ISODate } from "./dates";
import { formatMoney } from "./money";
import { pct } from "./notes";
import { verdictLine, type NoteVerdict, type VerdictLine } from "./note-verdict";

/** A credit-linked note; an older server (no note_type) and an unknown type read as equity. */
export function isCreditLinked(n: { note_type?: string | null; credit?: unknown } | null | undefined): boolean {
  return n?.note_type === "credit_linked" && !!n.credit;
}

/** "10.5% a year". */
export function yearlyRate(ratePct: string | null | undefined): string {
  return `${pct(ratePct)} a year`;
}

const FREQUENCY: Record<string, string> = {
  monthly: "monthly",
  quarterly: "quarterly",
  semiannual: "every six months",
  annual: "yearly",
  at_maturity: "at maturity",
};

/** How often coupons are paid, in words ("monthly", "every six months"); an unknown one as its words. */
export function frequencyText(f: CouponFrequency | null | undefined): string {
  return FREQUENCY[f ?? ""] ?? (f ?? "").replace(/_/g, " ");
}

// ── the verdict, at length ─────────────────────────────────────────────────

export interface CreditVerdict {
  headline: VerdictLine;
  lines: string[];
}

/**
 * The note page's verdict for a credit-linked note: a short headline ("Paying 10.5% a year") and
 * the lines under it (the next coupon and maturity; or what has built up, when it is paid and what
 * a call on the next date returns). Null for any other verdict.
 */
export function creditVerdict(
  v: NoteVerdict | null | undefined,
  credit: Pick<NoteCredit, "call_dates" | "if_called_next"> | null | undefined,
  currency: string,
  today: ISODate = todayDubai(),
): CreditVerdict | null {
  const money = (x: string | null | undefined) => formatMoney(x, { currency });
  const tone = verdictLine(v, today, currency)?.tone ?? "neutral";
  if (v?.kind === "cln_paying") {
    const parts = [v.amount && v.date ? `Next coupon ${money(v.amount)} on ${formatDate(v.date)}` : null, v.maturity_date ? `matures ${formatDate(v.maturity_date)}` : null].filter(Boolean);
    const line = parts.join(" · ");
    return { headline: { text: `Paying ${yearlyRate(v.rate_pct)}`, tone }, lines: line ? [line.charAt(0).toUpperCase() + line.slice(1)] : [] };
  }
  if (v?.kind === "cln_accruing") {
    const callable = !!v.call_date || (credit?.call_dates.length ?? 0) > 0;
    const lines: string[] = [];
    if (v.amount) {
      const when = v.maturity_date ? `paid at maturity (${formatDate(v.maturity_date)})` : "paid at maturity";
      lines.push(`${money(v.amount)} accrued so far, ${when}${callable ? " or if the issuer calls it" : ""}`);
    }
    const call = credit?.if_called_next;
    if (call) lines.push(`If called on ${formatDate(call.date)}: ${money(call.total)} back (${formatMoney(call.profit, { currency, signed: true })})`);
    return { headline: { text: `${yearlyRate(v.rate_pct)}, building up`, tone }, lines };
  }
  return null;
}

// ── the reference entity ───────────────────────────────────────────────────

/** "Example Airlines Group Inc" and "Senior · Standard North American Corporate". */
export function entityLines(c: Pick<NoteCredit, "reference_entity" | "seniority" | "transaction_type">): { entity: string; detail: string | null } {
  const detail = [c.seniority, c.transaction_type].filter((x): x is string => !!x?.trim()).join(" · ");
  return { entity: c.reference_entity, detail: detail || null };
}

/**
 * What a credit event means for this note, in plain words, with what is at risk today (the
 * server's credit_event). A note that has ended says what happened instead, or nothing.
 */
export function creditEventText(c: Pick<NoteCredit, "reference_entity" | "interest_at_maturity" | "credit_event">, status: string, currency: string): string | null {
  const money = (x: string) => formatMoney(x, { currency });
  const e = c.reference_entity;
  if (status === "credit_event") return `${e} had a credit event: interest stopped and the note repays what the market recovers.`;
  const risk = c.credit_event;
  if (!risk) return null;
  let text =
    `If ${e} has a credit event (default, bankruptcy or restructuring), interest stops and the note repays what the market recovers, possibly far below 100%. ` +
    `At risk now: ${money(risk.principal_at_risk)} face value and ${money(risk.interest_lost)} of interest to come`;
  if (c.interest_at_maturity && Number(risk.accrued_lost) > 0) text += `, including the ${money(risk.accrued_lost)} accrued so far, since nothing is paid until maturity`;
  if (Number(risk.kept) > 0) text += `; the ${money(risk.kept)} already received is kept`;
  return `${text}.`;
}

// ── coupon schedule ────────────────────────────────────────────────────────

const COUPON_STATUS: Record<string, { label: string; tone: "positive" | "muted" }> = {
  paid: { label: "Paid", tone: "positive" },
  to_come: { label: "To come", tone: "muted" },
  before_purchase: { label: "Before you bought", tone: "muted" },
  not_paid: { label: "Not paid", tone: "muted" },
};

/** A coupon's status in words; one this build doesn't know reads as its words, never blank. */
export function couponStatus(s: string | null | undefined): { label: string; tone: "positive" | "muted" } {
  const known = COUPON_STATUS[s ?? ""];
  if (known) return known;
  const words = (s ?? "").replace(/_/g, " ").trim();
  return { label: words ? words.charAt(0).toUpperCase() + words.slice(1) : "—", tone: "muted" };
}

/**
 * The schedule's one-line summary: "25 of 87 paid · USD 2,114.58 received · USD 5,425.00 to come";
 * interest paid at maturity: "Paid at maturity · USD 18,276.90 to come". Coupons from before the
 * purchase don't count; received and to come are the server's (received.coupons, remaining_coupons).
 */
export function scheduleHint(
  c: Pick<NoteCredit, "interest_at_maturity" | "remaining_coupons"> & { schedule: readonly Pick<CreditCoupon, "status">[] },
  receivedCoupons: string | null | undefined,
  currency: string,
): string {
  const money = (x: string) => formatMoney(x, { currency });
  const owned = c.schedule.filter((r) => r.status !== "before_purchase");
  const parts = [c.interest_at_maturity ? "Paid at maturity" : `${owned.filter((r) => r.status === "paid").length} of ${owned.length} paid`];
  if (Number(receivedCoupons) > 0) parts.push(`${money(receivedCoupons!)} received`);
  if (Number(c.remaining_coupons) > 0) parts.push(`${money(c.remaining_coupons)} to come`);
  return parts.join(" · ");
}

export interface CouponRow {
  seq: number;
  date: string;
  /** Interest paid at maturity: "Interest from 13 Feb 2025 at 13.25% a year"; null for a periodic coupon. */
  description: string | null;
  amount: string;
  status: string;
  tone: "positive" | "muted";
  /** The coupon paid next (the first still to come). */
  next: boolean;
}

/** The schedule as table rows, in date order (the server's); amounts formatted in the note's currency. */
export function couponRows(
  c: Pick<NoteCredit, "interest_at_maturity" | "coupon_rate_pct" | "interest_start_date"> & { schedule: readonly CreditCoupon[] },
  currency: string,
): CouponRow[] {
  const next = c.schedule.find((r) => r.status === "to_come")?.seq ?? null;
  return c.schedule.map((r) => {
    const s = couponStatus(r.status);
    return {
      seq: r.seq,
      date: formatDate(r.pay_date),
      description: c.interest_at_maturity ? `Interest from ${formatDate(c.interest_start_date ?? r.period_start)} at ${yearlyRate(c.coupon_rate_pct)}` : null,
      amount: formatMoney(r.amount, { currency }),
      status: s.label,
      tone: s.tone,
      next: r.seq === next,
    };
  });
}

// ── issuer call dates ──────────────────────────────────────────────────────

/** Each call date, the next one marked; those before it have passed. */
export function callDateRows(c: Pick<NoteCredit, "call_dates" | "next_call_date">): { date: string; label: string; next: boolean; passed: boolean }[] {
  const next = c.next_call_date;
  return c.call_dates.map((d) => ({ date: d, label: formatDate(d), next: d === next, passed: next ? d < next : true }));
}

/** "The issuer may repay at 100% plus accrued interest on these dates, with at least 10 business days' notice." */
export function callNoticeText(noticeDays: string | null | undefined): string {
  const days = Number(noticeDays);
  const notice = noticeDays && Number.isFinite(days) && days > 0 ? `, with at least ${days} business day${days === 1 ? "" : "s"}' notice` : "";
  return `The issuer may repay at 100% plus accrued interest on these dates${notice}.`;
}

// ── terms ──────────────────────────────────────────────────────────────────

/** "10.5% a year, paid monthly, 30/360, from 15 Oct 2024" / "13.25% a year, paid at maturity or call". */
export function couponTermsText(c: Pick<NoteCredit, "coupon_rate_pct" | "coupon_frequency" | "day_count" | "interest_at_maturity" | "interest_start_date" | "call_dates">): string {
  if (c.interest_at_maturity || c.coupon_frequency === "at_maturity") return `${yearlyRate(c.coupon_rate_pct)}, paid at maturity${c.call_dates.length > 0 ? " or call" : ""}`;
  return [yearlyRate(c.coupon_rate_pct), `paid ${frequencyText(c.coupon_frequency)}`, c.day_count, c.interest_start_date ? `from ${formatDate(c.interest_start_date)}` : null].filter(Boolean).join(", ");
}

/** "20 Dec 2031; as late as 20 Dec 2032 if a credit event is being determined". */
export function maturityTermsText(c: Pick<NoteCredit, "maturity_date" | "longstop_maturity_date">): string {
  const m = formatDate(c.maturity_date);
  return c.longstop_maturity_date && c.longstop_maturity_date !== c.maturity_date ? `${m}; as late as ${formatDate(c.longstop_maturity_date)} if a credit event is being determined` : m;
}

/** "Example Airlines Group Inc (Senior, Standard North American Corporate)". */
export function entityTermsText(c: Pick<NoteCredit, "reference_entity" | "seniority" | "transaction_type">): string {
  const detail = [c.seniority, c.transaction_type].filter((x): x is string => !!x?.trim()).join(", ");
  return detail ? `${c.reference_entity} (${detail})` : c.reference_entity;
}

/** The held-to-maturity tile's line: "+USD 5,390 · 6.2% a year" (profit formatted by the caller). */
export function annualisedText(annualisedPct: string | null | undefined): string | null {
  return annualisedPct ? `${pct(annualisedPct, 1)} a year` : null;
}
