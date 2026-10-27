import { lazy, Suspense, useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { CalendarClock, ChevronLeft, RefreshCw, ScrollText } from "lucide-react";
import { useCancelNote, useNoteDetail, useRefreshNotePrices, type NoteDetail, type NoteOutcome } from "@/data/notes";
import { errorMessage } from "@/data/api";
import { calledNext, distanceMet, distanceText, isEnded, levelLabel, maturityTableRows, noteStatus, outcomeLabel, outcomeTone, payoutRows, pct, sellFromMarket } from "@/lib/notes";
import { formatDate } from "@/lib/dates";
import { formatMoney } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { EmptyState, ErrorState, LoadingBlock, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { FormError } from "@/components/cash/bank-account-dialogs";
import { SellOrWait } from "./sell-or-wait";

// The chart library loads after the page renders (as on Overview, WEB-53).
const NoteChart = lazy(() => import("./note-chart").then((m) => ({ default: m.NoteChart })));

/** One structured note (Wealth → Investments): where it stands, what comes next, what it can pay. */
export function NoteView({ profileCode, holdingCode, isOwner }: { profileCode: string; holdingCode: string; isOwner: boolean }) {
  const q = useNoteDetail(profileCode, holdingCode);
  const refresh = useRefreshNotePrices(profileCode);
  const toast = useToast();
  const [cancelling, setCancelling] = useState(false);
  const n = q.data;

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <div>
        <Link to="/wealth/investments" className="tap -ml-1 inline-flex items-center gap-1 text-[13px] text-muted hover:text-accent">
          <ChevronLeft className="size-3.5" /> Investments
        </Link>
        <header className="mt-3 flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <h1 className="font-display text-[26px] leading-tight text-ink md:text-[30px]">{n ? n.name : <Skeleton className="h-8 w-64" />}</h1>
            {n && (
              <p className="mt-1 flex flex-wrap items-center gap-2 text-[13px] text-muted">
                <Badge tone={noteStatus(n.status).tone}>{noteStatus(n.status).label}</Badge>
                {n.awaiting_prices && <Badge tone="warn">Awaiting prices</Badge>}
                <span>{[n.isin, n.issuer, n.institution].filter(Boolean).join(" · ")}</span>
              </p>
            )}
          </div>
          {n && isOwner && !isEnded(n.status) && (
            <Button
              size="sm"
              icon={<RefreshCw className="size-3.5" />}
              loading={refresh.isPending}
              onClick={() =>
                refresh.mutate(undefined, {
                  onSuccess: (r) => toast({ title: "Prices updated", description: r.failed.length ? `No prices for: ${r.failed.join(", ")}` : `${r.stored} closes stored.`, tone: r.failed.length ? "neutral" : "positive" }),
                  onError: (e) => toast({ title: "Couldn't update prices", description: errorMessage(e), tone: "danger" }),
                })
              }
            >
              Update prices
            </Button>
          )}
        </header>
      </div>

      {q.isLoading ? (
        <Card>
          <LoadingRows rows={3} />
        </Card>
      ) : q.isError || !n ? (
        <Card>
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        </Card>
      ) : (
        <>
          <Summary n={n} />
          {!isEnded(n.status) && (n.market || n.if_called_next) && (
            <SellOrWait sell={sellFromMarket(n.market)} called={calledNext(n.if_called_next)} currency={n.currency} />
          )}
          {!isEnded(n.status) && <NextCard n={n} />}
          <SharesCard n={n} />
          {n.scenarios && <ScenariosCard n={n} />}
          <ScheduleCard n={n} />
          <TermsCard n={n} />
          {isOwner && n.status !== "cancelled" && (
            <div className="flex justify-end">
              <Button size="sm" variant="ghost" onClick={() => setCancelling(true)}>
                Remove this note…
              </Button>
            </div>
          )}
          {isOwner && <CancelDialog profileCode={profileCode} n={cancelling ? n : null} onClose={() => setCancelling(false)} />}
        </>
      )}
    </div>
  );
}

function Stat({ label, children, sub, tone }: { label: string; children: ReactNode; sub?: ReactNode; tone?: "positive" | "danger" }) {
  return (
    <div className="min-w-0">
      <p className="text-[11px] font-medium tracking-[0.06em] text-subtle uppercase">{label}</p>
      <p className={cn("tabular mt-1 text-lg font-semibold text-ink", tone === "positive" && "text-positive", tone === "danger" && "text-danger")}>{children}</p>
      {sub && <p className="mt-0.5 text-[12px] text-muted">{sub}</p>}
    </div>
  );
}

const money = (v: string | null | undefined, currency: string) => formatMoney(v, { currency });
// formatMoney writes the minus itself; a gain gets a plus.
const signed = (v: string | null | undefined, currency: string) => (v === null || v === undefined ? "—" : `${Number(v) >= 0 ? "+" : ""}${formatMoney(v, { currency, bare: true })}`);
const toneOf = (v: string | null | undefined) => (v === null || v === undefined ? undefined : Number(v) < 0 ? ("danger" as const) : ("positive" as const));

function Summary({ n }: { n: NoteDetail }) {
  const c = n.currency;
  const today = n.if_ended_today;
  return (
    <Card className="grid grid-cols-2 gap-5 p-5 md:grid-cols-4">
      <Stat label="Invested" sub={`${money(n.nominal, c)} nominal at ${pct(n.purchase_price_pct)} · ${formatDate(n.trade_date)}`}>
        {money(n.invested, c)}
      </Stat>
      <Stat label="Received" sub={`Coupons ${money(n.received.coupons, c)}${Number(n.due.total) > 0 ? ` · ${money(n.due.total, c)} due` : ""}`}>
        {money(n.received.total, c)}
      </Stat>
      {n.result ? (
        <>
          <Stat label="Result" tone={toneOf(n.result.profit)} sub={`${pct(n.result.return_pct)} on what you put in`}>
            {signed(n.result.profit, c)}
          </Stat>
          <Stat label="Ended" sub={noteStatus(n.status).label}>
            {n.ended_on ? formatDate(n.ended_on) : "—"}
          </Stat>
        </>
      ) : (
        <>
          <Stat
            label="If it ended today"
            tone={toneOf(today?.profit)}
            sub={today ? `${pct(today.payout_pct)} of nominal${today.settlement === "physical" ? " in shares" : ""}, with coupons received` : "Needs today's prices"}
          >
            {today ? signed(today.profit, c) : "—"}
          </Stat>
          <Stat label="Break-even at maturity" sub={`Matures ${formatDate(n.maturity_date)}; coupons aside`}>
            {n.break_even_pct ? `worst ≥ ${pct(n.break_even_pct)}` : "—"}
          </Stat>
        </>
      )}
    </Card>
  );
}

function NextCard({ n }: { n: NoteDetail }) {
  const next = n.next;
  const c = n.currency;
  return (
    <Card>
      <CardHeader eyebrow="Next observation" title={next ? `${formatDate(next.obs_date)} · in ${next.days} day${next.days === 1 ? "" : "s"}` : "None left"} />
      <div className="grid grid-cols-1 gap-4 px-5 pb-5 sm:grid-cols-3">
        {next?.coupon && (
          <Outlook
            title={`Coupon ${pct(next.coupon.rate_pct)}${Number(n.memory_unpaid_pct) > 0 ? " (with missed ones)" : ""}`}
            ok={next.coupon.would_pay}
            yes={`Would pay ${money(next.coupon.amount, c)} on ${formatDate(next.pay_date)}`}
            no={`Not at today's prices: the worst share must be at ${pct(next.coupon.barrier_pct)} or above`}
          />
        )}
        {next?.autocall && (
          <Outlook
            title={`Autocall at ${pct(next.autocall.trigger_pct)}`}
            ok={next.autocall.would_call}
            yes={`Would repay ${money(next.autocall.amount, c)} (${pct(next.autocall.redemption_pct)}) and end the note`}
            no={`Not at today's prices: every share must be at ${pct(next.autocall.trigger_pct)} of its initial level`}
          />
        )}
        {next?.is_final && n.if_ended_today && (
          <Outlook title="Final valuation" ok={Number(n.if_ended_today.profit) >= 0} yes={`At today's prices it repays ${money(n.if_ended_today.amount, c)}`} no={`At today's prices it repays ${money(n.if_ended_today.amount, c)}`} />
        )}
        {n.worst_now && (
          <div className="rounded-md bg-surface-2/60 px-4 py-3 text-[13px]">
            <p className="font-medium text-ink">Worst share now</p>
            <p className="mt-1 text-ink-2">
              {n.worst_now.symbol} at <span className="tabular font-medium">{pct(n.worst_now.pct, 2)}</span> of its initial level
            </p>
          </div>
        )}
      </div>
    </Card>
  );
}

function Outlook({ title, ok, yes, no }: { title: string; ok: boolean; yes: string; no: string }) {
  return (
    <div className={cn("rounded-md px-4 py-3 text-[13px]", ok ? "bg-positive-soft" : "bg-warn-soft")}>
      <p className="font-medium text-ink">{title}</p>
      <p className={cn("mt-1", ok ? "text-positive" : "text-warn")}>{ok ? yes : no}</p>
    </div>
  );
}

function SharesCard({ n }: { n: NoteDetail }) {
  const live = !isEnded(n.status);
  return (
    <Card>
      <CardHeader eyebrow="The shares it follows" title="Against the barriers" />
      <div className="overflow-x-auto px-5">
        <table className="w-full min-w-[640px] text-[13px]">
          <thead className="text-left text-[11px] text-subtle uppercase">
            <tr className="border-b border-border">
              <th className="py-2 pr-3 font-medium">Share</th>
              <th className="py-2 pr-3 text-right font-medium">Initial</th>
              <th className="py-2 pr-3 text-right font-medium">Last close</th>
              <th className="py-2 pr-3 text-right font-medium">Level</th>
              {live && <th className="py-2 pr-3 font-medium">Autocall</th>}
              {live && <th className="py-2 pr-3 font-medium">Coupon</th>}
              {live && <th className="py-2 font-medium">Break-even</th>}
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {n.underlyings.map((u) => (
              <tr key={u.symbol}>
                <td className="py-2 pr-3">
                  <span className="font-medium text-ink">{u.symbol}</span> {u.is_worst && live && <Badge tone="warn">worst</Badge>}
                  <span className="block text-[12px] text-muted">{u.name}</span>
                </td>
                <td className="tabular py-2 pr-3 text-right">{u.initial}</td>
                <td className="tabular py-2 pr-3 text-right">
                  {u.close ?? "—"}
                  {u.close_date && <span className="block text-[11px] text-muted">{formatDate(u.close_date, "short")}</span>}
                </td>
                <td className="tabular py-2 pr-3 text-right font-medium text-ink">{pct(u.perf_pct, 2)}</td>
                {live && <DistanceCell d={u.to_autocall_pct} level={u.autocall_level} />}
                {live && <DistanceCell d={u.to_coupon_pct} level={u.coupon_level} />}
                {live && <DistanceCell d={u.to_break_even_pct} level={u.break_even_level} />}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {live && n.levels && n.levels.length > 0 && n.worst_now && (
        <div className="border-t border-border px-5 py-3">
          <p className="mb-2 text-[12px] text-muted">The worst share ({n.worst_now.symbol}, {pct(n.worst_now.pct, 2)}) against each level:</p>
          <ul className="grid grid-cols-1 gap-x-6 gap-y-1.5 text-[13px] sm:grid-cols-2">
            {n.levels.map((l) => (
              <li key={`${l.kind}-${l.pct}`} className="flex items-baseline justify-between gap-3">
                <span className="text-ink-2">
                  {levelLabel(l)} <span className="tabular text-muted">({pct(l.pct)}, {formatDate(l.date, "short")})</span>
                </span>
                <span className={cn("tabular whitespace-nowrap font-medium", distanceMet(l.distance_pct) ? "text-positive" : "text-warn")}>{distanceText(l.distance_pct)}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
      {Object.keys(n.series).length > 0 && (
        <div className="border-t border-border px-5 py-4">
          <Suspense fallback={<LoadingBlock className="h-64" />}>
            <NoteChart series={n.series} levels={live ? n.levels : null} />
          </Suspense>
        </div>
      )}
    </Card>
  );
}

function DistanceCell({ d, level }: { d: string | null; level: string | null }) {
  if (d === null) return <td className="py-2 pr-3 text-muted">—</td>;
  return (
    <td className="py-2 pr-3">
      <span className={cn("tabular font-medium", distanceMet(d) ? "text-positive" : "text-warn")}>{distanceText(d)}</span>
      {level && <span className="tabular block text-[11px] text-muted">at {level}</span>}
    </td>
  );
}

function ScenariosCard({ n }: { n: NoteDetail }) {
  const s = n.scenarios!;
  const c = n.currency;
  const curve = maturityTableRows(s.maturity, n.payout);
  return (
    <Card>
      <CardHeader eyebrow="What it can pay" title="Scenarios" />
      <div className="grid grid-cols-2 gap-5 px-5 pb-4 md:grid-cols-4">
        <Stat label="Best case" tone="positive" sub={s.best.date ? `${s.best.when === "autocall" ? "Called" : "Matures"} ${formatDate(s.best.date)}, every coupon paid` : undefined}>
          {signed(s.best.profit, c)}
        </Stat>
        <Stat label="Worst case" tone="danger" sub="The worst share falls to zero; coupons received kept">
          {signed(s.worst.profit, c)}
        </Stat>
        <Stat label="Coupons still to come" sub="If every remaining one is paid">
          {money(s.remaining_coupons, c)}
        </Stat>
        <Stat label="Break-even at maturity" sub="Worst share level that returns what you paid">
          {n.break_even_pct ? pct(n.break_even_pct) : "—"}
        </Stat>
      </div>
      <div className="grid grid-cols-1 gap-6 border-t border-border px-5 py-4 xl:grid-cols-2">
        {s.autocall.length > 0 && (
          <div className="min-w-0">
            <h3 className="mb-2 text-[13px] font-semibold text-ink">You win: called early</h3>
            <p className="mb-2 text-[12px] text-muted">If every share is at the trigger on that date (coupons up to it paid).</p>
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
          <h3 className="mb-2 text-[13px] font-semibold text-ink">At maturity, by where the worst share ends</h3>
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
                  <th className="py-1 pr-2 font-medium">Worst share</th>
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
    </Card>
  );
}

function ScheduleCard({ n }: { n: NoteDetail }) {
  const byDate = new Map<string, NoteOutcome[]>();
  for (const o of n.outcomes) byDate.set(o.obs_date, [...(byDate.get(o.obs_date) ?? []), o]);
  const c = n.currency;
  return (
    <Card>
      <CardHeader eyebrow={`${n.observations.length} observation dates`} title="Schedule and outcomes" />
      {n.observations.length === 0 ? (
        <EmptyState icon={<CalendarClock />} title="No observations">
          Only the final valuation on {formatDate(n.terms.final_valuation_date)}.
        </EmptyState>
      ) : (
        <div className="max-h-[28rem] overflow-auto px-5 pb-4">
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
                            {x.amount ? ` ${money(x.amount, c)}` : ""} · worst {x.worst_symbol} {pct(x.worst_pct)}
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
    </Card>
  );
}

function TermsCard({ n }: { n: NoteDetail }) {
  const t = n.terms;
  const rows: [string, ReactNode][] = [
    ["Product", n.product_name],
    ["Issuer", [n.issuer, t.guarantor && `guaranteed by ${t.guarantor}`].filter(Boolean).join(", ") || "—"],
    ["Denomination", `${money(t.denomination, n.currency)} at ${pct(t.issue_price_pct)} issue price`],
    ["Strike · final valuation · maturity", `${formatDate(t.strike_date)} · ${formatDate(t.final_valuation_date)} · ${formatDate(t.maturity_date)}`],
    ["Term sheet", t.termsheet_filename ?? "—"],
  ];
  return (
    <Card>
      <CardHeader eyebrow="As read from the term sheet" title="Terms" />
      <dl className="grid grid-cols-1 gap-x-6 gap-y-2 px-5 pb-5 text-[13px] sm:grid-cols-[max-content_1fr]">
        {rows.map(([k, v]) => (
          <div key={k} className="contents">
            <dt className="text-muted">{k}</dt>
            <dd className="text-ink-2 [overflow-wrap:anywhere]">{v}</dd>
          </div>
        ))}
      </dl>
    </Card>
  );
}

function CancelDialog({ profileCode, n, onClose }: { profileCode: string; n: NoteDetail | null; onClose: () => void }) {
  const cancel = useCancelNote(profileCode);
  const toast = useToast();
  return (
    <Dialog open={!!n} onOpenChange={(o) => !o && onClose()} title="Remove this note?" description="For a note added by mistake. Its purchase, coupons and redemptions leave the account's ledger; the terms are kept.">
      {n && (
        <div className="flex flex-col gap-4">
          <p className="flex items-center gap-2 text-sm text-ink-2">
            <ScrollText className="size-4" /> {n.name}
          </p>
          <FormError error={cancel.isError ? errorMessage(cancel.error) : null} />
          <div className="flex justify-end gap-2">
            <Button onClick={onClose}>Keep it</Button>
            <Button
              variant="danger"
              loading={cancel.isPending}
              onClick={() =>
                cancel.mutate(n.holding_code, {
                  onSuccess: () => {
                    toast({ title: "Note removed", description: n.name, tone: "positive" });
                    onClose();
                  },
                })
              }
            >
              Remove
            </Button>
          </div>
        </div>
      )}
    </Dialog>
  );
}
