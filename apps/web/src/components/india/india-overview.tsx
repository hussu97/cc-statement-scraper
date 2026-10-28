import { lazy, Suspense, useMemo, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronRight, LineChart, TrendingUp } from "lucide-react";
import { aedLine, changeText, formatInr, indiaPoints, indiaTabPath, periodFigures, positionsText, type IndiaAccount, type IndiaOverview } from "@/lib/india";
import { investmentPeriodTitle, type InvestmentPeriod } from "@/lib/investments";
import { signTone } from "@/lib/holdings";
import { formatDate, formatRelative } from "@/lib/dates";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { EmptyState, LoadingBlock } from "@/components/ui/states";
import { HeroAmount } from "@/components/ledger";
import { BankLogo } from "@/components/bank-logo";

// The chart library loads after the page renders (as on Overview, WEB-53).
const IndiaValueChart = lazy(() => import("./india-chart").then((m) => ({ default: m.IndiaValueChart })));

const TONE_TEXT = { positive: "text-positive", danger: "text-danger", neutral: "text-ink" } as const;

function Signed({ amount, pct, currency, empty = "Not known yet", className }: { amount: string | null; pct?: string | null; currency: string; empty?: string; className?: string }) {
  const t = changeText(amount, pct ?? null, currency);
  if (t === null) return <span className="text-muted">{empty}</span>;
  return <span className={cn("tabular", TONE_TEXT[signTone(amount)], className)}>{t}</span>;
}

function Figure({ label, children, sub }: { label: string; children: ReactNode; sub?: ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-[12px] text-subtle">{label}</dt>
      <dd className="mt-0.5">{children}</dd>
      {sub && <dd className="tabular mt-0.5 text-[12px] text-muted">{sub}</dd>}
    </div>
  );
}

/** Kite and Coin now: the total in INR (AED under it), invested, P&L, cash and the last 24 hours. */
export function IndiaSummary({ o }: { o: IndiaOverview }) {
  const t = o.total;
  const c = o.currency;
  return (
    <section aria-labelledby="india-total" className="animate-rise">
      <p id="india-total" className="text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">
        Kite and Coin
      </p>
      <div className="mt-2">
        <HeroAmount value={t.value} currency={c} />
        <p className="tabular mt-1 text-sm text-muted">{aedLine(t.value_aed)}</p>
        <dl className="mt-4 flex flex-wrap gap-x-8 gap-y-3 text-sm">
          <Figure label="P&L">
            <Signed amount={t.pnl} pct={t.pnl_pct} currency={c} />
          </Figure>
          <Figure label="Invested">
            <span className="tabular text-ink">{formatInr(t.invested, { currency: c })}</span>
          </Figure>
          <Figure label="Cash">
            <span className="tabular text-ink">{formatInr(t.cash, { currency: c })}</span>
          </Figure>
          <Figure label="Last 24 hours" sub={t.change_24h_aed !== null ? aedLine(t.change_24h_aed, { signed: true }) : undefined}>
            <Signed amount={t.change_24h} pct={t.change_24h_pct} currency={c} />
          </Figure>
        </dl>
        <p className="mt-3 text-[12px] text-subtle">
          {[positionsText(t.positions), t.last_synced_at ? `synced ${formatRelative(t.last_synced_at)}` : null].filter(Boolean).join(" · ")}
        </p>
      </div>
    </section>
  );
}

/** The value against what was invested, over the page's period (the period returns' too). */
export function IndiaChartCard({ o, period, stale }: { o: IndiaOverview; period: InvestmentPeriod; stale?: boolean }) {
  const points = useMemo(() => indiaPoints(o.series), [o.series]);
  const empty = points.filter((p) => p.value !== null).length < 2;
  return (
    <Card className={cn(stale && "opacity-60")}>
      <CardHeader eyebrow={investmentPeriodTitle(period)} title="Value over time" />
      <div className="px-3 pb-4 md:px-4">
        {empty ? (
          <EmptyState icon={<LineChart />} title="Not enough history yet" className="h-56">
            The line starts once Kite or Coin has synced on two days in this period.
          </EmptyState>
        ) : (
          <Suspense fallback={<LoadingBlock className="h-56" />}>
            <IndiaValueChart points={points} currency={o.currency} />
          </Suspense>
        )}
      </div>
      {!empty && <p className="px-5 pb-4 text-[11px] text-subtle">Kite and Coin at each day's prices. The dashed line is what was invested by then.</p>}
    </Card>
  );
}

/** The period's returns: where it started, the money added at cost, and the growth beyond that. */
export function IndiaReturnsCard({ o, stale }: { o: IndiaOverview; stale?: boolean }) {
  const t = o.total;
  const c = o.currency;
  const f = periodFigures(t, c);
  const known = t.period_start_value !== null || t.period_end_value !== null;
  return (
    <Card className={cn(stale && "opacity-60")}>
      <CardHeader eyebrow="Returns" title="New money and growth" />
      {!known ? (
        <EmptyState icon={<TrendingUp />} title="No returns for this period yet">
          Returns show once Kite or Coin has a value at the start of the period.
        </EmptyState>
      ) : (
        <div className="px-5 pb-5">
          <dl className="grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-4">
            <Figure label="Start value">
              <span className="tabular text-[17px] font-medium text-ink">{f.start}</span>
            </Figure>
            <Figure label="Added">
              <span className="tabular text-[17px] font-medium text-ink">{f.added}</span>
            </Figure>
            <Figure label="Growth">
              <span className={cn("tabular text-[17px] font-medium", TONE_TEXT[signTone(t.period_growth)])}>{f.growth}</span>
            </Figure>
            <Figure label="Growth %">
              <span className={cn("tabular text-[17px] font-medium", f.growthPct ? TONE_TEXT[signTone(t.period_growth_pct)] : "text-muted")}>{f.growthPct ?? "—"}</span>
            </Figure>
          </dl>
          {o.from && (
            <p className="mt-3 text-[11px] text-subtle">
              From {formatDate(o.from)} to {o.to ? formatDate(o.to) : "today"}, ending at {f.end}. Added is money that came into the accounts (a buy paid from their own
              cash adds nothing); growth is the change in value beyond it.
            </p>
          )}
        </div>
      )}
    </Card>
  );
}

/** A row per India account (Kite, Coin), linking to its tab. */
export function IndiaAccountsCard({ o }: { o: IndiaOverview }) {
  return (
    <Card>
      <CardHeader eyebrow="Accounts" title="Kite and Coin" />
      <ul className="divide-y divide-border border-t border-border">
        {o.accounts.map((a) => (
          <li key={a.account_code}>
            <AccountRow a={a} currency={o.currency} />
          </li>
        ))}
      </ul>
    </Card>
  );
}

function AccountRow({ a, currency }: { a: IndiaAccount; currency: string }) {
  const to = indiaTabPath(a);
  const sync = a.sync_status === "error" ? "Sync failed" : a.last_synced_at ? `Synced ${formatRelative(a.last_synced_at)}` : "Not synced yet";
  const body = (
    <>
      <BankLogo bankCode={a.bank_code} size="md" decorative />
      {/* On a phone the figures sit under the name, so neither is cut short. */}
      <span className="flex min-w-0 flex-1 flex-col gap-1.5 sm:flex-row sm:items-center sm:gap-3">
        <span className="min-w-0 flex-1">
          <span className="block truncate text-[13.5px] font-medium text-ink group-hover:text-accent">{a.name}</span>
          <span className={cn("block truncate text-[12px]", a.sync_status === "error" ? "text-warn" : "text-muted")}>
            {[positionsText(a.positions), sync].filter(Boolean).join(" · ")}
          </span>
        </span>
        <span className="tabular flex flex-wrap items-baseline gap-x-3 text-[13px] sm:block sm:shrink-0 sm:text-right">
          <span className="block font-medium text-ink">{formatInr(a.value, { currency })}</span>
          <span className="block text-[12px]">
            <Signed amount={a.pnl} pct={a.pnl_pct} currency={currency} empty="P&L not known" />
          </span>
          <span className="block text-[11.5px] text-muted">
            24h <Signed amount={a.change_24h} pct={a.change_24h_pct} currency={currency} empty="—" className="text-[11.5px]" />
          </span>
        </span>
      </span>
      {to && <ChevronRight className="size-4 shrink-0 text-subtle group-hover:text-ink-2" />}
    </>
  );
  const row = "group flex items-center gap-3 px-5 py-3";
  return to ? (
    <Link to={to} className={cn("tap", row, "hover:bg-surface-2/60 focus-visible:bg-surface-2/60")}>
      {body}
    </Link>
  ) : (
    <div className={row}>{body}</div>
  );
}
