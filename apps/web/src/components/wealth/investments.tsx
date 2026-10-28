import { lazy, Suspense, useMemo } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowRight, Coins, LineChart } from "lucide-react";
import { useHoldingsValuation, useHoldingsValueSeries, type HoldingsValuation } from "@/data/holdings";
import { formatPct, gainNote, holdingsPoints, investmentNotes, partialDaysNote, signTone } from "@/lib/holdings";
import { investmentPeriodRange, investmentPeriodTitle, type InvestmentPeriod } from "@/lib/investments";
import { formatTotal, type MoneyInput } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card, CardHeader, Skeleton } from "@/components/ui/display";
import { EmptyState, ErrorState, LoadingBlock, LoadingRows } from "@/components/ui/states";
import { HeroAmount } from "@/components/ledger";

const HoldingsValueChart = lazy(() => import("./holdings-chart").then((m) => ({ default: m.HoldingsValueChart })));

export const TONE_TEXT = { positive: "text-positive", danger: "text-danger", neutral: "text-ink" } as const;

/** A signed AED amount coloured by its sign: "+AED 1,250" / "−AED 300"; "—" when unknown. */
export function SignedTotal({ value, className }: { value: MoneyInput; className?: string }) {
  return <span className={cn("tabular", TONE_TEXT[signTone(value)], className)}>{formatTotal(value, { signed: true, empty: "—" })}</span>;
}

/** "+AED 1,250 (+3.1%)": a gain with its percentage of cost, both the server's. */
function GainFigure({ gain, pct, className }: { gain: MoneyInput; pct: MoneyInput; className?: string }) {
  const p = formatPct(pct, { signed: true });
  return (
    <span className={cn("tabular", TONE_TEXT[signTone(gain)], className)}>
      {formatTotal(gain, { signed: true })}
      {p && <span className="ml-1 text-[0.85em]">({p})</span>}
    </span>
  );
}

// ── the page's summary ─────────────────────────────────────────────────────

/** Investments now (holdings_valuation): total value, gain on what was put in, the last 24 hours. */
export function InvestmentsSummary({ q }: { q: ReturnType<typeof useHoldingsValuation> }) {
  return (
    <section aria-labelledby="investments-total" className="animate-rise">
      <p id="investments-total" className="text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">
        All investments
      </p>
      {q.isLoading ? (
        <div className="mt-3 flex flex-col gap-3" role="status" aria-label="Loading">
          <Skeleton className="h-14 w-64" />
          <Skeleton className="h-4 w-80 max-w-full" />
        </div>
      ) : q.isError || !q.data ? (
        <Card className="mt-3">
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        </Card>
      ) : (
        <SummaryBody v={q.data} />
      )}
    </section>
  );
}

function SummaryBody({ v }: { v: HoldingsValuation }) {
  const notes = investmentNotes(v);
  const costNote = gainNote(v);
  return (
    <div className="mt-2">
      <HeroAmount value={v.value_aed} />
      <dl className="mt-4 flex flex-wrap gap-x-8 gap-y-3 text-sm">
        <div>
          <dt className="text-[12px] text-subtle">Gain on what you put in</dt>
          <dd className="mt-0.5">{v.gain_aed === null ? <span className="text-muted">Add what you put in to see it</span> : <GainFigure gain={v.gain_aed} pct={v.gain_pct} />}</dd>
        </div>
        {v.cost_aed !== null && (
          <div>
            <dt className="text-[12px] text-subtle">Put in</dt>
            <dd className="tabular mt-0.5 text-ink">{formatTotal(v.cost_aed)}</dd>
          </div>
        )}
        <div>
          <dt className="text-[12px] text-subtle">Last 24 hours</dt>
          <dd className="mt-0.5">{v.change_24h_aed === null ? <span className="text-muted">Not known yet</span> : <SignedTotal value={v.change_24h_aed} />}</dd>
        </div>
      </dl>
      {costNote && <p className="mt-3 text-[12px] text-muted">{costNote}.</p>}
      {notes.length > 0 && <p className="mt-1 text-[12px] text-warn">{notes.join("; ")}.</p>}
    </div>
  );
}

// ── chart ──────────────────────────────────────────────────────────────────

/** The holdings' value against what was paid, over Investments' period (the returns' too). */
export function InvestmentsChartCard({ profileCode, period }: { profileCode: string; period: InvestmentPeriod }) {
  const range = useMemo(() => investmentPeriodRange(period), [period]);
  const q = useHoldingsValueSeries(profileCode, range);
  const points = useMemo(() => holdingsPoints(q.data ?? []), [q.data]);
  const empty = !points.some((p) => p.value !== null);

  return (
    <Card>
      <CardHeader eyebrow={investmentPeriodTitle(period)} title="Value over time" />
      <div className="px-3 pb-4 md:px-4">
        {q.isLoading ? (
          <LoadingBlock className="h-56" />
        ) : q.isError ? (
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        ) : empty ? (
          <EmptyState icon={<LineChart />} title="Nothing to chart yet" className="h-56">
            Add an investment: the chart shows what your holdings were worth each day, from when each began, against what you put in.
          </EmptyState>
        ) : (
          <Suspense fallback={<LoadingBlock className="h-56" />}>
            <HoldingsValueChart points={points} />
          </Suspense>
        )}
      </div>
      {!q.isLoading && !q.isError && !empty && (
        <div className="px-5 pb-4 text-[11px] text-subtle">
          <p>Your holdings at each day's prices and values. The dashed line is what you had put in by then.</p>
          {partialDaysNote(points) && <p className="mt-1 text-muted">{partialDaysNote(points)}</p>}
        </div>
      )}
    </Card>
  );
}

// ── the Wealth overview's card ─────────────────────────────────────────────

/** Investments in a few lines on the Wealth overview, linking to the page. */
export function InvestmentsCard({ profileCode }: { profileCode: string }) {
  const q = useHoldingsValuation(profileCode);
  const v = q.data;
  return (
    <Card>
      <CardHeader
        eyebrow="Investments"
        title="What you hold"
        action={
          <Link to="/wealth/investments" className="tap inline-flex items-center gap-1 text-[13px] text-accent hover:underline">
            Investments <ArrowRight className="size-3.5" />
          </Link>
        }
      />
      {q.isLoading ? (
        <LoadingRows rows={3} />
      ) : q.isError || !v ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : v.holdings_count === 0 ? (
        <EmptyState icon={<Coins />} title="No investments yet">
          Add gold, a savings plan, a broker account, shares or a deposit on the Investments page: Bank Ledger values them and counts them in your net worth.
        </EmptyState>
      ) : (
        <div className="px-5 pb-5">
          <p className="tabular text-2xl font-medium text-ink">{formatTotal(v.value_aed)}</p>
          <p className="text-[12px] text-subtle">
            {v.holdings_count} {v.holdings_count === 1 ? "holding" : "holdings"}
          </p>
          <dl className="mt-3 flex flex-col gap-1 text-sm">
            <div className="flex items-baseline justify-between gap-3">
              <dt className="text-ink-2">Gain on what you put in</dt>
              <dd>{v.gain_aed === null ? <span className="text-muted">Nothing put in recorded</span> : <GainFigure gain={v.gain_aed} pct={v.gain_pct} />}</dd>
            </div>
            <div className="flex items-baseline justify-between gap-3">
              <dt className="text-ink-2">Last 24 hours</dt>
              <dd>{v.change_24h_aed === null ? <span className="text-muted">Not known yet</span> : <SignedTotal value={v.change_24h_aed} />}</dd>
            </div>
          </dl>
        </div>
      )}
    </Card>
  );
}
