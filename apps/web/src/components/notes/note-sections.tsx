import { lazy, Suspense, useState, type ReactNode } from "react";
import { CalendarClock, ChevronDown, FileText } from "lucide-react";
import type { NoteDetail, NoteOutcome } from "@/data/notes";
import { isEnded, maturityTableRows, outcomeLabel, outcomeTone, payoutRows, pct } from "@/lib/notes";
import { formatDate } from "@/lib/dates";
import { formatMoney } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card } from "@/components/ui/display";
import { EmptyState, LoadingBlock } from "@/components/ui/states";
import { TermSheetDialog } from "./term-sheet-dialog";

// A note's detail, one tap away and closed by default (the note page leads with its verdict, its
// stocks and its money): every scenario, the full schedule, the price history and the terms.

// The chart library loads only when the section opens (as on Overview, WEB-53).
const NoteChart = lazy(() => import("./note-chart").then((m) => ({ default: m.NoteChart })));

const money = (v: string | null | undefined, currency: string) => formatMoney(v, { currency });
// formatMoney writes the minus itself; a gain gets a plus.
const signed = (v: string | null | undefined, currency: string) => formatMoney(v, { currency, signed: true });

/** A card that opens on a tap (native <details>, as the document log). */
export function Collapsible({ title, hint, children }: { title: string; hint?: string; children: ReactNode }) {
  return (
    <Card className="overflow-hidden">
      <details className="[&[open]_.note-chevron]:rotate-180">
        <summary className="tap flex cursor-pointer list-none items-center justify-between gap-3 px-5 py-3.5 [&::-webkit-details-marker]:hidden">
          <span className="min-w-0">
            <span className="text-[14px] font-semibold text-ink">{title}</span>
            {hint && <span className="ml-2 text-[12px] text-muted">{hint}</span>}
          </span>
          <ChevronDown className="note-chevron size-4 shrink-0 text-subtle transition-transform" aria-hidden />
        </summary>
        <div className="border-t border-border">{children}</div>
      </details>
    </Card>
  );
}

function Stat({ label, children, sub, tone }: { label: string; children: ReactNode; sub?: ReactNode; tone?: "positive" | "danger" }) {
  return (
    <div className="min-w-0">
      <p className="text-[12px] text-subtle">{label}</p>
      <p className={cn("tabular mt-0.5 text-[15px] font-medium text-ink", tone === "positive" && "text-positive", tone === "danger" && "text-danger")}>{children}</p>
      {sub && <p className="mt-0.5 text-[12px] text-muted">{sub}</p>}
    </div>
  );
}

/** Each stock since the strike, as % of its start, against the note's levels. */
export function PriceHistorySection({ n }: { n: NoteDetail }) {
  if (Object.keys(n.series).length === 0) return null;
  return (
    <Collapsible title="Price history">
      <div className="px-5 py-4">
        <Suspense fallback={<LoadingBlock className="h-64" />}>
          <NoteChart series={n.series} levels={isEnded(n.status) ? null : n.levels} />
        </Suspense>
      </div>
    </Collapsible>
  );
}

export function ScenariosSection({ n }: { n: NoteDetail }) {
  const s = n.scenarios!;
  const c = n.currency;
  const curve = maturityTableRows(s.maturity, n.payout);
  return (
    <Collapsible title="All scenarios">
      <div className="grid grid-cols-2 gap-5 px-5 py-4 md:grid-cols-4">
        <Stat label="Best case" tone="positive" sub={s.best.date ? `${s.best.when === "autocall" ? "Called" : "Matures"} ${formatDate(s.best.date)}, every coupon paid` : undefined}>
          {signed(s.best.profit, c)}
        </Stat>
        <Stat label="Worst case" tone="danger" sub="The stock holding it back falls to zero; coupons received kept">
          {signed(s.worst.profit, c)}
        </Stat>
        <Stat label="Coupons still to come" sub="If every remaining one is paid">
          {money(s.remaining_coupons, c)}
        </Stat>
        <Stat label="Break-even at maturity" sub="Where the lowest stock must end to return what you paid">
          {n.break_even_pct ? pct(n.break_even_pct) : "—"}
        </Stat>
      </div>
      <div className="grid grid-cols-1 gap-6 border-t border-border px-5 py-4 xl:grid-cols-2">
        {s.autocall.length > 0 && (
          <div className="min-w-0">
            <h3 className="mb-2 text-[13px] font-semibold text-ink">You win: called early</h3>
            <p className="mb-2 text-[12px] text-muted">If every stock is at the trigger on that date (coupons up to it paid).</p>
            <div className="max-h-80 overflow-auto">
              <table className="w-full min-w-[420px] text-[13px]">
                <thead className="sticky top-0 bg-surface text-left text-[11px] text-subtle uppercase">
                  <tr>
                    <th className="py-1 pr-2 font-medium">Observed</th>
                    <th className="py-1 pr-2 text-right font-medium">Trigger</th>
                    <th className="py-1 pr-2 text-right font-medium">You get</th>
                    <th className="py-1 pr-2 text-right font-medium">Profit</th>
                    <th className="py-1 text-right font-medium">A year</th>
                  </tr>
                </thead>
                <tbody>
                  {s.autocall.map((r) => (
                    <tr key={r.obs_date} className="border-t border-border/60">
                      <td className="py-1 pr-2">{formatDate(r.obs_date)}</td>
                      <td className="tabular py-1 pr-2 text-right">{pct(r.trigger_pct)}</td>
                      <td className="tabular py-1 pr-2 text-right">{money(r.total, c)}</td>
                      <td className={cn("tabular py-1 pr-2 text-right", Number(r.profit) < 0 ? "text-danger" : "text-positive")}>{signed(r.profit, c)}</td>
                      <td className="tabular py-1 text-right">{r.annualised_pct ? pct(r.annualised_pct) : "—"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
        <div className="min-w-0">
          <h3 className="mb-2 text-[13px] font-semibold text-ink">At maturity, by where the lowest stock ends</h3>
          <ul className="mb-2 text-[12px] text-muted">
            {payoutRows(n.payout).map((r) => (
              <li key={r.when}>
                {r.when}: <span className="text-ink-2">{r.pays}</span>
                {r.physical && " in shares"}
              </li>
            ))}
          </ul>
          <div className="max-h-80 overflow-auto">
            <table className="w-full min-w-[360px] text-[13px]">
              <thead className="sticky top-0 bg-surface text-left text-[11px] text-subtle uppercase">
                <tr>
                  <th className="py-1 pr-2 font-medium">Lowest stock</th>
                  <th className="py-1 pr-2 text-right font-medium">Repays</th>
                  <th className="py-1 text-right font-medium">Profit</th>
                </tr>
              </thead>
              <tbody>
                {[...curve].reverse().map((p) => (
                  <tr key={p.worst_pct} className="border-t border-border/60">
                    <td className="tabular py-1 pr-2">{pct(p.worst_pct)}</td>
                    <td className="tabular py-1 pr-2 text-right">
                      {money(p.amount, c)}
                      {p.settlement === "physical" && Number(p.amount) > 0 && <span className="text-[11px] text-muted"> in shares</span>}
                    </td>
                    <td className={cn("tabular py-1 text-right", Number(p.profit) < 0 ? "text-danger" : "text-positive")}>{signed(p.profit, c)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="mt-2 text-[11px] text-muted">Profit counts the coupons received so far, not future ones.</p>
        </div>
      </div>
    </Collapsible>
  );
}

export function ScheduleSection({ n }: { n: NoteDetail }) {
  const byDate = new Map<string, NoteOutcome[]>();
  for (const o of n.outcomes) byDate.set(o.obs_date, [...(byDate.get(o.obs_date) ?? []), o]);
  const c = n.currency;
  return (
    <Collapsible title="Full schedule" hint={`${n.observations.length} dates`}>
      {n.observations.length === 0 ? (
        <EmptyState icon={<CalendarClock />} title="No observations">
          Only the final valuation on {formatDate(n.terms.final_valuation_date)}.
        </EmptyState>
      ) : (
        <div className="max-h-[28rem] overflow-auto px-5 py-3">
          <table className="w-full min-w-[640px] text-[13px]">
            <thead className="sticky top-0 bg-surface text-left text-[11px] text-subtle uppercase">
              <tr>
                <th className="py-1 pr-2 font-medium">Observed</th>
                <th className="py-1 pr-2 font-medium">Paid</th>
                <th className="py-1 pr-2 font-medium">Coupon</th>
                <th className="py-1 pr-2 font-medium">Autocall</th>
                <th className="py-1 font-medium">Outcome</th>
              </tr>
            </thead>
            <tbody>
              {n.observations.map((o) => {
                const outs = byDate.get(o.obs_date) ?? [];
                return (
                  <tr key={o.obs_date} className="border-t border-border/60 align-top">
                    <td className="py-1 pr-2">{formatDate(o.obs_date)}</td>
                    <td className="py-1 pr-2 text-muted">{formatDate(o.pay_date)}</td>
                    <td className="tabular py-1 pr-2">{o.coupon_rate_pct ? `${pct(o.coupon_rate_pct)} if ≥ ${pct(o.coupon_barrier_pct)}${o.coupon_memory ? " (memory)" : ""}` : "—"}</td>
                    <td className="tabular py-1 pr-2">{o.autocall_trigger_pct ? `${pct(o.autocall_amount_pct)} if ≥ ${pct(o.autocall_trigger_pct)}` : "—"}</td>
                    <td className="py-1">
                      {outs.length === 0 ? (
                        <span className="text-subtle">{n.awaiting_prices && o.obs_date <= (n.next?.obs_date ?? o.obs_date) ? "awaiting prices" : "to come"}</span>
                      ) : (
                        outs.map((x) => (
                          <span key={x.kind} className={cn("block", outcomeTone(x.kind) === "positive" ? "text-positive" : "text-muted")}>
                            {outcomeLabel(x.kind)}
                            {x.amount ? ` ${money(x.amount, c)}` : ""} · lowest {x.worst_symbol} {pct(x.worst_pct)}
                          </span>
                        ))
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Collapsible>
  );
}

export function TermsSection({ profileCode, n }: { profileCode: string; n: NoteDetail }) {
  const t = n.terms;
  const [viewing, setViewing] = useState(false);
  const rows: [string, ReactNode][] = [
    ["Product", n.product_name],
    ["ISIN", n.isin ?? "—"],
    ["Issuer", [n.issuer, t.guarantor && `guaranteed by ${t.guarantor}`].filter(Boolean).join(", ") || "—"],
    ["Denomination", `${money(t.denomination, n.currency)} at ${pct(t.issue_price_pct)} issue price`],
    ["Bought", `${money(n.nominal, n.currency)} face value at ${pct(n.purchase_price_pct)} on ${formatDate(n.trade_date)}`],
    ["Break-even at maturity", n.break_even_pct ? `every stock at or above ${pct(n.break_even_pct)} of its start` : "—"],
    ["Strike · final valuation · maturity", `${formatDate(t.strike_date)} · ${formatDate(t.final_valuation_date)} · ${formatDate(t.maturity_date)}`],
    [
      "Term sheet",
      t.termsheet_path ? (
        <button
          type="button"
          onClick={() => setViewing(true)}
          className="tap inline-flex items-start gap-1.5 text-left text-accent underline-offset-4 hover:underline"
        >
          <FileText className="mt-0.5 size-3.5 shrink-0" aria-hidden />
          <span>{t.termsheet_filename?.trim() || "View term sheet"}</span>
        </button>
      ) : (
        "—"
      ),
    ],
  ];
  return (
    <Collapsible title="Terms" hint="as read from the term sheet">
      <dl className="grid grid-cols-1 gap-x-6 gap-y-2 px-5 py-4 text-[13px] sm:grid-cols-[max-content_1fr]">
        {rows.map(([k, v]) => (
          <div key={k} className="contents">
            <dt className="text-muted">{k}</dt>
            <dd className="text-ink-2 [overflow-wrap:anywhere]">{v}</dd>
          </div>
        ))}
      </dl>
      {t.termsheet_path && (
        <TermSheetDialog
          profileCode={profileCode}
          path={t.termsheet_path}
          filename={t.termsheet_filename}
          title={n.name}
          open={viewing}
          onOpenChange={setViewing}
        />
      )}
    </Collapsible>
  );
}
