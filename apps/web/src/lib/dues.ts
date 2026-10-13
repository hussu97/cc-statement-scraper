// A statement's due state as a badge: the server's payment status (public.v_statement_payments,
// audit WEB-36 / UX-1r) and the days left to the due date. Whether a statement was paid is never
// worked out here (CLAUDE.md §2.2): the server matches the payments. Pure; unit-tested.
import { formatTotal, toAmount, type MoneyInput } from "./money";

/** public.v_statement_payments.payment_status. */
export type PaymentStatus = "paid" | "part_paid" | "unpaid" | "overdue";

export type DueTone = "positive" | "warn" | "danger";

export interface DueBadge {
  label: string;
  tone: DueTone;
}

/** Upcoming dues are flagged this many days ahead. */
export const DUE_SOON_DAYS = 7;

/** "Due today", "Due tomorrow", "Due in 5 days"; null for a past date. */
export function dueLabel(days: number | null): string | null {
  if (days === null || days < 0) return null;
  if (days === 0) return "Due today";
  if (days === 1) return "Due tomorrow";
  return `Due in ${days} days`;
}

/** The server's status, or null for anything else (an older server sends none). */
export function paymentStatusOf(v: unknown): PaymentStatus | null {
  return v === "paid" || v === "part_paid" || v === "unpaid" || v === "overdue" ? v : null;
}

/**
 * The badge for a statement: Paid / Part paid / Overdue from the server, otherwise a due
 * countdown inside DUE_SOON_DAYS. Null when there is nothing to say: an unpaid or unknown
 * statement due later, or one whose due date has passed without a status (never a guess).
 */
export function dueBadge(status: unknown, daysToDue: number | null): DueBadge | null {
  switch (paymentStatusOf(status)) {
    case "paid":
      return { label: "Paid", tone: "positive" };
    case "overdue":
      return { label: "Overdue", tone: "danger" };
    case "part_paid":
      return { label: "Part paid", tone: "warn" };
    default: {
      const label = daysToDue !== null && daysToDue <= DUE_SOON_DAYS ? dueLabel(daysToDue) : null;
      return label ? { label, tone: daysToDue! <= 2 ? "danger" : "warn" } : null;
    }
  }
}

/**
 * "AED 1,511 paid" under a statement that is part paid or overdue with something paid: how far
 * the payments got. Null otherwise (paid in full says it all; nothing paid has nothing to show).
 */
export function paidNote(status: unknown, amountPaid: MoneyInput): string | null {
  const s = paymentStatusOf(status);
  if (s !== "part_paid" && s !== "overdue") return null;
  const n = toAmount(amountPaid);
  return n !== null && n > 0 ? `${formatTotal(amountPaid)} paid` : null;
}
