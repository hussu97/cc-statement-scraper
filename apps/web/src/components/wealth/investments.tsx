import { lazy, Suspense, useMemo, useState } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowRight, Coins, LineChart } from "lucide-react";
import { useHoldingsValuation, useHoldingsValueSeries, useMetalPriceSeries, type HoldingsValuation, type MetalPrice } from "@/data/holdings";
import {
  PRICE_CHART_QUOTES,
  PRICE_STRIP,
  formatPct,
  gainNote,
  holdingsPoints,
  investmentNotes,
  investmentRange,
  partialDaysNote,
  pricePoints,
  quoteLabel,
  signTone,
} from "@/lib/holdings";
import { formatRelative } from "@/lib/dates";
import { formatMoney, formatTotal, type MoneyInput } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader, Skeleton } from "@/components/ui/display";
import { Segmented } from "@/components/ui/segmented";
import { EmptyState, ErrorState, LoadingBlock, LoadingRows } from "@/components/ui/states";
import { HeroAmount } from "@/components/ledger";

const HoldingsValueChart = lazy(() => import("./holdings-chart").then((m) => ({ default: m.HoldingsValueChart })));
const MetalPriceChart = lazy(() => import("./holdings-chart").then((m) => ({ default: m.MetalPriceChart })));

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

// ── prices ─────────────────────────────────────────────────────────────────

/** Today's Dubai retail rates per gram, with the 24-hour change and the age of each. */
export function PriceStrip({ q }: { q: ReturnType<typeof useHoldingsValuation> }) {
  return (
    <Card>
      <CardHeader eyebrow="Dubai retail, per gram" title="Prices" />
      {q.isLoading ? (
        <LoadingRows rows={1} />
      ) : q.isError || !q.data ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : PRICE_STRIP.every((k) => !q.data.prices[k]) ? (
        <EmptyState icon={<Coins />} title="No prices yet">
          Bank Ledger fetches gold and silver prices every 6 hours. They appear after the first fetch.
        </EmptyState>
      ) : (
        <ul className="grid grid-cols-2 gap-px border-t border-border bg-border lg:grid-cols-5">
          {PRICE_STRIP.map((k) => (
            <PriceTile key={k} label={quoteLabel(k)} price={q.data.prices[k]} />
          ))}
        </ul>
      )}
      <p className="px-5 py-3 text-[11px] text-subtle">Gold: Dubai Jewellery Group rates. Silver: Dubai retail rate. Refreshed every 6 hours.</p>
    </Card>
  );
}

function PriceTile({ label, price }: { label: string; price: MetalPrice | undefined }) {
  const change = price ? formatPct(price.change_24h_pct, { signed: true }) : null;
  return (
    <li className="flex flex-col gap-0.5 bg-surface px-5 py-3 last:odd:col-span-2 lg:last:odd:col-span-1">
      <span className="text-[12px] text-subtle">{label}</span>
      {price ? (
        <>
          <span className="tabular text-base font-medium text-ink">{formatMoney(price.aed_per_gram)}</span>
          <span className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-subtle">
            {change && <span className={cn("tabular", TONE_TEXT[signTone(price.change_24h_pct)])}>{change} 24h</span>}
            <span>{formatRelative(price.as_of)}</span>
            {price.is_stale && <Badge tone="warn">Stale</Badge>}
          </span>
        </>
      ) : (
        <span className="text-sm text-muted">No price yet</span>
      )}
    </li>
  );
}

// ── chart ──────────────────────────────────────────────────────────────────

type ChartView = "value" | (typeof PRICE_CHART_QUOTES)[number]["value"];
const CHART_VIEWS: { value: ChartView; label: string }[] = [{ value: "value", label: "Value vs put in" }, ...PRICE_CHART_QUOTES];

/** 90 days: the holdings' value against what was paid, or the 24K / silver price. */
export function InvestmentsChartCard({ profileCode }: { profileCode: string }) {
  const [view, setView] = useState<ChartView>("value");
  const range = useMemo(() => investmentRange(), []);
  const value = useHoldingsValueSeries(profileCode, range);
  const price = useMetalPriceSeries(view === "value" ? "gold_24k" : view, range, view !== "value");
  const valuePoints = useMemo(() => holdingsPoints(value.data ?? []), [value.data]);
  const prices = useMemo(() => pricePoints(price.data ?? []), [price.data]);
  const q = view === "value" ? value : price;
  const empty = view === "value" ? !valuePoints.some((p) => p.value !== null) : !prices.some((p) => p.price !== null);
  const label = CHART_VIEWS.find((c) => c.value === view)?.label ?? "";

  return (
    <Card>
      <CardHeader
        eyebrow="Last 90 days"
        title={view === "value" ? "Value over time" : `${label} per gram`}
        action={
          // A wrapper hides it on phones: Segmented's own inline-flex would win over `hidden` (cn doesn't merge).
          <div className="hidden sm:block">
            <Segmented ariaLabel="Chart" value={view} onChange={setView} options={CHART_VIEWS} />
          </div>
        }
      />
      <div className="px-5 pb-3 sm:hidden">
        <Segmented ariaLabel="Chart" value={view} onChange={setView} options={CHART_VIEWS} />
      </div>
      <div className="px-3 pb-4 md:px-4">
        {q.isLoading ? (
          <LoadingBlock className="h-56" />
        ) : q.isError ? (
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        ) : empty ? (
          <EmptyState icon={<LineChart />} title={view === "value" ? "Nothing to chart yet" : "No prices yet"} className="h-56">
            {view === "value"
              ? "Add an investment: the chart shows what your holdings were worth each day, from when each began, against what you put in."
              : "The price history fills in from the first fetch, every 6 hours."}
          </EmptyState>
        ) : (
          <Suspense fallback={<LoadingBlock className="h-56" />}>
            {view === "value" ? <HoldingsValueChart points={valuePoints} /> : <MetalPriceChart points={prices} label={label} />}
          </Suspense>
        )}
      </div>
      {view === "value" && !empty && (
        <div className="px-5 pb-4 text-[11px] text-subtle">
          <p>Your holdings at each day's prices and values. The dashed line is what you had put in by then.</p>
          {partialDaysNote(valuePoints) && <p className="mt-1 text-muted">{partialDaysNote(valuePoints)}</p>}
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
  const notes = v ? investmentNotes(v) : [];
  const costNote = v ? gainNote(v) : null;
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
          {costNote && <p className="mt-3 text-[12px] text-muted">{costNote}.</p>}
          {notes.length > 0 && <p className="mt-1 text-[12px] text-warn">{notes.join("; ")}.</p>}
        </div>
      )}
    </Card>
  );
}
