import { CalendarClock, Landmark } from "lucide-react";
import type { NoteDetail } from "@/data/notes";
import { callDateRows, callNoticeText, couponRows, creditEventText, entityLines, scheduleHint } from "@/lib/credit-notes";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { EmptyState } from "@/components/ui/states";
import { Collapsible } from "./note-sections";

// A credit-linked note's own sections (lib/credit-notes words them): the reference entity in the
// stocks' place, then its coupon schedule and the issuer's call dates, collapsed like the rest.

/** Whose credit the note rides on, and what a credit event would cost today. */
export function ReferenceEntityCard({ n }: { n: NoteDetail }) {
  const c = n.credit;
  if (!c) return null;
  const { entity, detail } = entityLines(c);
  const risk = creditEventText(c, n.status, n.currency);
  return (
    <Card>
      <CardHeader title="Reference entity" />
      <div className="max-w-3xl px-5 pb-4">
        <p className="flex items-start gap-2 text-[15px] font-medium text-ink">
          <Landmark className="mt-0.5 size-4 shrink-0 text-subtle" aria-hidden />
          <span className="min-w-0">
            {entity}
            {detail && <span className="block text-[12px] font-normal text-muted">{detail}</span>}
          </span>
        </p>
        {c.reference_obligation_isin && (
          <p className="mt-2 text-[13px] text-muted">
            Reference bond <span className="tabular text-ink-2">{c.reference_obligation_isin}</span>
          </p>
        )}
        {risk && <p className={cn("mt-3 text-[13px] leading-relaxed", n.status === "credit_event" ? "text-danger" : "text-ink-2")}>{risk}</p>}
      </div>
    </Card>
  );
}

export function CouponScheduleSection({ n }: { n: NoteDetail }) {
  const c = n.credit;
  if (!c) return null;
  const rows = couponRows(c, n.currency);
  const described = rows.some((r) => r.description);
  return (
    <Collapsible title="Coupon schedule" hint={scheduleHint(c, n.received.coupons, n.currency)}>
      {rows.length === 0 ? (
        <EmptyState icon={<CalendarClock />} title="No coupons">
          The term sheet lists no coupon dates.
        </EmptyState>
      ) : (
        <div className="max-h-[28rem] overflow-auto px-5 py-3">
          <table className={cn("w-full text-[13px]", described ? "min-w-[480px]" : "min-w-[320px]")}>
            <thead className="sticky top-0 bg-surface text-left text-[11px] text-subtle uppercase">
              <tr>
                <th className="py-1 pr-2 font-medium">Paid on</th>
                {described && <th className="py-1 pr-2 font-medium">Coupon</th>}
                <th className="py-1 pr-2 text-right font-medium">Amount</th>
                <th className="py-1 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.seq} className={cn("border-t border-border/60", r.next && "bg-surface-2/60")}>
                  <td className="py-1 pr-2">{r.date}</td>
                  {described && <td className="py-1 pr-2 text-ink-2">{r.description}</td>}
                  <td className="tabular py-1 pr-2 text-right">{r.amount}</td>
                  <td className={cn("py-1", r.tone === "positive" ? "text-positive" : "text-muted")}>
                    {r.status}
                    {r.next && <span className="text-ink-2"> · next</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Collapsible>
  );
}

/** When the issuer may repay early; nothing for a note it can't call. */
export function CallDatesSection({ n }: { n: NoteDetail }) {
  const c = n.credit;
  if (!c || c.call_dates.length === 0) return null;
  const rows = callDateRows(c);
  const next = rows.find((r) => r.next);
  return (
    <Collapsible title="Issuer call dates" hint={next ? `next ${next.label}` : `${rows.length} dates`}>
      <div className="px-5 py-4">
        <ul className="flex flex-wrap gap-x-4 gap-y-1.5 text-[13px]">
          {rows.map((r) => (
            <li key={r.date} className={cn("tabular", r.next ? "font-medium text-ink" : r.passed ? "text-subtle" : "text-ink-2")}>
              {r.label}
              {r.next && <span className="font-normal text-muted"> · next</span>}
            </li>
          ))}
        </ul>
        <p className="mt-3 text-[12px] text-muted">{callNoticeText(c.call_notice_days)}</p>
      </div>
    </Collapsible>
  );
}
