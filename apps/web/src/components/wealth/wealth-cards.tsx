import { lazy, Suspense, useMemo } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowLeftRight, ArrowRight, CreditCard, LineChart, Lightbulb } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useNetWorth, useNetWorthSeries, type NetWorth } from "@/data/wealth";
import { useCashFlow } from "@/data/cash";
import { accountLabel, isWealthInsight, sortInsights, useDismissInsight, useInsights } from "@/data/overview";
import { formatFlow, formatNet, monthFlows, netTone } from "@/lib/cash-flow";
import { cardAnchorNote, netWorthHistoryMonths, netWorthNotes, netWorthPoints } from "@/lib/wealth";
import { formatOutstanding } from "@/lib/balances";
import { formatMonth, formatRelative, monthEnd, monthStart, todayDubai } from "@/lib/dates";
import { formatCount, formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader, Skeleton } from "@/components/ui/display";
import { EmptyState, ErrorState, LoadingBlock, LoadingRows } from "@/components/ui/states";
import { HeroAmount } from "@/components/ledger";
import { BankLogo } from "@/components/bank-logo";
import { InsightCard } from "@/components/insights/insight-card";

const NetWorthChart = lazy(() => import("./net-worth-chart").then((m) => ({ default: m.NetWorthChart })));

const TONE_TEXT = { positive: "text-positive", danger: "text-danger", neutral: "text-ink" } as const;

/** Net worth now (public.net_worth): bank cash + investments − what the cards owe, with honest completeness. */
export function NetWorthHero({ profileCode }: { profileCode: string }) {
  const q = useNetWorth(profileCode);
  return (
    <section aria-labelledby="net-worth-title" className="animate-rise">
      <p id="net-worth-title" className="text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">
        Net worth
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
        <HeroBody n={q.data} />
      )}
    </section>
  );
}

function HeroBody({ n }: { n: NetWorth }) {
  const notes = netWorthNotes(n);
  return (
    <div className="mt-2">
      <h1 className="sr-only">Net worth</h1>
      <HeroAmount value={n.net_aed} />
      <dl className="mt-4 flex flex-wrap gap-x-8 gap-y-3 text-sm">
        <div className="relative">
          <dt className="text-[12px] text-subtle">Cash in bank accounts</dt>
          <dd className="tabular mt-0.5">
            <Link to="/wealth/accounts" className="text-ink after:absolute after:inset-0 hover:text-accent">
              {formatTotal(n.cash_aed)}
            </Link>
          </dd>
        </div>
        <div className="relative">
          <dt className="text-[12px] text-subtle">+ Investments</dt>
          <dd className="tabular mt-0.5">
            <Link to="/wealth/investments" className={cn("after:absolute after:inset-0 hover:text-accent", n.holdings_count > 0 ? "text-ink" : "text-muted")}>
              {n.holdings_count > 0 ? formatTotal(n.holdings_aed) : "None yet"}
            </Link>
          </dd>
        </div>
        <div className="relative">
          <dt className="text-[12px] text-subtle">− Owed on cards</dt>
          <dd className="tabular mt-0.5">
            <Link to="/cards" className="text-ink after:absolute after:inset-0 hover:text-accent">
              {formatOutstanding(n.owed_aed, n.owed_has_estimate)}
            </Link>
          </dd>
        </div>
        {n.cash_as_of && (
          <div>
            <dt className="text-[12px] text-subtle">Oldest bank balance</dt>
            <dd className="mt-0.5 text-ink-2">{formatRelative(n.cash_as_of)}</dd>
          </div>
        )}
      </dl>
      {notes.length > 0 && <p className="mt-3 text-[12px] text-warn">{notes.join("; ")}.</p>}
    </div>
  );
}

/** Net worth over time (net_worth_series). History starts with the first nightly snapshot. */
export function NetWorthHistoryCard({ profileCode }: { profileCode: string }) {
  const q = useNetWorthSeries(profileCode);
  const points = useMemo(() => netWorthPoints(q.data ?? []), [q.data]);
  const history = netWorthHistoryMonths(points);
  return (
    <Card>
      <CardHeader eyebrow="Month by month" title="Net worth over time" />
      <div className="px-3 pb-4 md:px-4">
        {q.isLoading ? (
          <LoadingBlock className="h-52" />
        ) : q.isError ? (
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        ) : history === 0 ? (
          <EmptyState icon={<LineChart />} title="History starts this month" className="h-52">
            Bank Ledger notes your net worth every night. From next month this chart shows how it moves, one point per month.
          </EmptyState>
        ) : (
          <Suspense fallback={<LoadingBlock className="h-52" />}>
            <NetWorthChart points={points} />
            {history < 3 && <p className="mt-1 px-2 text-[11px] text-subtle">Only {formatCount(history + 1)} months so far: the line fills in as the months go by.</p>}
          </Suspense>
        )}
      </div>
    </Card>
  );
}

/** What each card owes now (net_worth.cards): the liabilities side of net worth. */
export function OwedCardsCard({ profileCode }: { profileCode: string }) {
  const q = useNetWorth(profileCode);
  return (
    <Card>
      <CardHeader
        eyebrow="Liabilities"
        title="Owed on cards"
        action={
          <Link to="/cards" className="tap text-[13px] text-accent hover:underline">
            Cards & statements
          </Link>
        }
      />
      {q.isLoading ? (
        <LoadingRows rows={2} />
      ) : q.isError || !q.data ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : q.data.cards.length === 0 ? (
        <EmptyState icon={<CreditCard />} title="No cards">
          Cards appear from your first statement or card alert.
        </EmptyState>
      ) : (
        <ul className="divide-y divide-border border-t border-border">
          {q.data.cards.map((c) => (
            <li key={c.account_code} className="flex items-center gap-3 px-5 py-3">
              <BankLogo bankCode={c.bank_code} />
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-medium text-ink">{accountLabel(c)}</p>
                <p className="text-[11px] text-subtle">{cardAnchorNote(c.anchor_kind)}</p>
              </div>
              <p className={cn("tabular shrink-0 text-sm", c.outstanding_aed === null ? "text-muted" : "font-medium text-ink")}>
                {c.outstanding_aed === null ? "No balance yet" : formatOutstanding(c.outstanding_aed, c.has_estimate)}
              </p>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

/** This month's cash flow in a few lines (public.cash_flow), linking to the full page. */
export function MonthCashCard({ profileCode }: { profileCode: string }) {
  const thisMonth = monthStart(todayDubai());
  const q = useCashFlow(profileCode, { from: thisMonth, to: monthEnd(thisMonth) });
  const flows = useMemo(() => monthFlows(q.data ?? [], thisMonth), [q.data, thisMonth]);
  const lines = flows.groups.filter((g) => g.key !== "moves").flatMap((g) => g.lines);
  return (
    <Card>
      <CardHeader
        eyebrow="Cash flow"
        title={`${formatMonth(thisMonth)} so far`}
        action={
          <Link to="/wealth/cash-flow" search={{ month: undefined, account: undefined }} className="tap inline-flex items-center gap-1 text-[13px] text-accent hover:underline">
            Cash flow <ArrowRight className="size-3.5" />
          </Link>
        }
      />
      {q.isLoading ? (
        <LoadingRows rows={4} />
      ) : q.isError || !q.data ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : !flows.hasMovements ? (
        <EmptyState icon={<ArrowLeftRight />} title="No money moved this month yet">
          Income, transfers and spending appear here as alerts and statements arrive.
        </EmptyState>
      ) : (
        <div className="px-5 pb-5">
          {flows.partial && (
            <p className="mb-3 flex flex-wrap items-baseline gap-2 text-[12px] text-muted">
              <Badge tone="info">Partial month</Badge> Money in before your first bank alert or balance wasn't captured.
            </p>
          )}
          <ul className="flex flex-col">
            {lines.map((l) => (
              <li key={l.flow} className="flex items-baseline justify-between gap-3 py-1 text-sm">
                <span className="text-ink-2">{l.label}</span>
                <span className={cn("tabular", l.direction === "in" ? "text-positive" : "text-ink")}>{formatFlow(l.amount, l.direction)}</span>
              </li>
            ))}
          </ul>
          <div className="mt-2 flex items-baseline justify-between gap-3 border-t border-border pt-2">
            <span className="text-sm font-semibold text-ink">Net</span>
            <span className={cn("tabular text-base font-medium", flows.partial ? "text-muted" : TONE_TEXT[netTone(flows.net)])}>{formatNet(flows.net)}</span>
          </div>
        </div>
      )}
    </Card>
  );
}

/** Bank balance and income insights: the Wealth side of the nightly checks. */
export function WealthInsightsCard({ profileCode }: { profileCode: string }) {
  const { isOwner } = useActiveProfile();
  const q = useInsights(profileCode);
  const dismiss = useDismissInsight(profileCode);
  const list = useMemo(() => sortInsights((q.data ?? []).filter(isWealthInsight)), [q.data]);
  return (
    <Card>
      <CardHeader eyebrow="Worth a look" title="Accounts and income" />
      {q.isLoading ? (
        <LoadingRows rows={2} />
      ) : q.isError ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : list.length === 0 ? (
        <EmptyState icon={<Lightbulb />} title="All quiet">
          Every night Bank Ledger checks that balances are current, that alerts add up to the bank's balance, and that salary arrived on time.
        </EmptyState>
      ) : (
        <ul className="flex flex-col gap-2 px-5 pb-5">
          {list.map((i) => (
            <InsightCard key={i.insight_code} insight={i} onDismiss={isOwner ? () => dismiss.mutate(i.insight_code) : undefined} />
          ))}
        </ul>
      )}
    </Card>
  );
}
