import { useMemo } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { ArrowRight, ChevronLeft, ChevronRight } from "lucide-react";
import { categoryRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useFilterMeta } from "@/data/overview";
import { useCategoryBreakdown, useSpendBreakdown, type SpendBreakdown } from "@/data/analytics";
import { NO_TREND_FILTERS } from "@/lib/trend-filters";
import { insightsRange, withRange } from "@/lib/search";
import { formatMonth, type DateRange } from "@/lib/dates";
import { displayRatio, formatChange, formatPercent, formatTotal } from "@/lib/money";
import type { RpcReturn } from "@/lib/supabase";
import { Money } from "@/components/ledger";
import { Badge, Card, CardHeader, Dot, PageHeader, Skeleton } from "@/components/ui/display";
import { EmptyState, ErrorState, LoadingBlock, LoadingRows, QueryView } from "@/components/ui/states";
import { RangeControl } from "@/components/insights/range-control";
import { changeTone, countLabel, rangeLabel } from "@/components/insights/labels";
import { breakdownRowFor, categoryFilterKey, isCategoryParam, merchantActivitySearch, trendRange } from "@/components/insights/category-view";
import { MonthBars } from "@/components/charts/month-bars";
import { shortMonth } from "@/components/charts/heat";
import { categoryVar } from "@/components/charts/palette";

type BreakdownRow = RpcReturn<"category_breakdown">[number];

/** Top merchants kept by the server before it folds the rest into "Others". */
const TOP_MERCHANTS = 8;

/**
 * One category over time (MA-1): its monthly spend, its top merchants and the change against
 * the previous period, for the Insights range in the URL. Every figure is the server's:
 * category_breakdown for the total and change, and spend_breakdown filtered to this category for
 * the zero-filled months (category grouping) and the merchants (merchant grouping).
 */
export function CategoryPage() {
  const { profile_code: profileCode } = useActiveProfile();
  const { categoryCode } = categoryRoute.useParams();
  const search = categoryRoute.useSearch();
  const navigate = useNavigate({ from: "/insights/category/$categoryCode" });
  const { from, to } = insightsRange(search);
  const range = useMemo(() => ({ from, to }), [from, to]);
  const valid = isCategoryParam(categoryCode);
  const meta = useFilterMeta(profileCode);
  const breakdown = useCategoryBreakdown(profileCode, range);
  const row = breakdown.data ? breakdownRowFor(breakdown.data, categoryCode) : null;
  const metaCat = meta.data?.categories.find((c) => c.category_code === categoryCode);
  const name = categoryCode === "none" ? "Uncategorised" : (metaCat?.name ?? row?.name ?? null);
  const token = metaCat?.color_token ?? row?.color_token ?? null;
  const back = { tab: "categories", ...search };

  // A code that isn't this ledger's category: say so once both sources have answered.
  const unknown = !valid || (meta.isSuccess && breakdown.isSuccess && categoryCode !== "none" && !metaCat && !row);
  if (unknown) {
    return (
      <div className="animate-fade-in">
        <BackLink search={back} />
        <Card>
          <EmptyState title="Category not found" action={<Link to="/insights" search={{ tab: "categories" }} className="text-sm text-accent hover:underline">All categories</Link>}>
            This ledger has no such category. It may have been deleted, or the link is from another ledger.
          </EmptyState>
        </Card>
      </div>
    );
  }

  return (
    <div className="animate-fade-in">
      <BackLink search={back} />
      <PageHeader
        title={
          name ? (
            <span className="inline-flex items-center gap-3">
              <Dot token={token} className="size-3" />
              {name}
            </span>
          ) : (
            <Skeleton className="h-9 w-48" />
          )
        }
        description={`${rangeLabel(range.from, range.to)}: how this category's spending moves month to month, and where it goes.`}
        actions={<RangeControl search={search} onChange={(r) => void navigate({ search: withRange(r), replace: true })} />}
      />
      <div className="flex flex-col gap-6">
        <Summary query={breakdown} row={row} param={categoryCode} range={range} />
        <TrendAndMerchants profileCode={profileCode} param={categoryCode} range={range} token={token} />
      </div>
    </div>
  );
}

function BackLink({ search }: { search: Record<string, unknown> }) {
  return (
    <Link to="/insights" search={search} className="tap mb-3 inline-flex items-center gap-1 text-[13px] text-muted hover:text-ink">
      <ChevronLeft className="size-3.5" aria-hidden /> Categories
    </Link>
  );
}

function Summary({
  query,
  row,
  param,
  range,
}: {
  query: { data: BreakdownRow[] | undefined; isLoading: boolean; isError: boolean; error: unknown; refetch: () => unknown };
  row: BreakdownRow | null;
  param: string;
  range: DateRange;
}) {
  const activity = (
    <Link to="/activity" search={{ category: param, from: range.from, to: range.to }} className="tap inline-flex items-center gap-1 text-[13px] text-accent hover:underline">
      See transactions <ArrowRight className="size-3.5" aria-hidden />
    </Link>
  );
  if (query.isLoading) return <Card><LoadingRows rows={1} /></Card>;
  if (query.isError || !query.data) return <Card><ErrorState error={query.error} onRetry={() => void query.refetch()} /></Card>;
  if (!row) {
    return (
      <Card>
        <EmptyState title="No spending in this range" action={activity}>
          Nothing was spent in this category between {rangeLabel(range.from, range.to)}. Pick a longer range to see its history.
        </EmptyState>
      </Card>
    );
  }
  // Server fraction vs the previous period of the same length; null when that period had no spend.
  const delta = formatChange(row.change);
  const tone = changeTone(row.change);
  return (
    <Card className="p-5">
      <dl className="grid grid-cols-2 gap-x-6 gap-y-5 md:grid-cols-4">
        <Stat label="Spent">
          <Money value={row.amount} total className="display-num text-2xl text-ink" />
        </Stat>
        <Stat label="vs previous period">
          <span className="flex flex-wrap items-center gap-2">
            {delta ? <Badge tone={tone === "neutral" ? "neutral" : tone} className="tabular">{delta}</Badge> : <Badge tone="neutral">New</Badge>}
            <span className="text-[12px] text-subtle">{delta ? `was ${formatTotal(row.prev_amount)}` : "nothing the period before"}</span>
          </span>
        </Stat>
        <Stat label="Share of spending">
          <span className="tabular text-lg text-ink">{formatPercent(row.share, row.share < 0.1 ? 1 : 0)}</span>
        </Stat>
        <Stat label="Transactions">
          <span className="flex flex-col items-start gap-0.5">
            <span className="tabular text-lg text-ink">{countLabel(row.txn_count, "transaction")}</span>
            {activity}
          </span>
        </Stat>
      </dl>
    </Card>
  );
}

function Stat({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-[12px] text-subtle">{label}</dt>
      <dd className="mt-1">{children}</dd>
    </div>
  );
}

function TrendAndMerchants({ profileCode, param, range, token }: { profileCode: string; param: string; range: DateRange; token: string | null }) {
  const filters = useMemo(() => ({ ...NO_TREND_FILTERS, categories: [categoryFilterKey(param)] }), [param]);
  const trend = trendRange(range);
  // The category's own zero-filled monthly totals (one group), over at least six months.
  const trendQ = useSpendBreakdown(profileCode, trend, "category", 1, filters);
  // Its merchants in the selected range: the top few, the rest folded into "Others" by the server.
  const merchantsQ = useSpendBreakdown(profileCode, range, "merchant", TOP_MERCHANTS, filters);
  const color = categoryVar(token);
  return (
    <div className="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
      <Card>
        <CardHeader eyebrow={rangeLabel(trend.from, trend.to)} title="Month by month" />
        <QueryView
          query={trendQ}
          loading={<LoadingBlock className="h-56" />}
          isEmpty={(d) => d.groups.length === 0}
          empty={<EmptyState title="No spending in these months">Pick a longer range to see how this category moves.</EmptyState>}
        >
          {(d) => <Trend data={d} color={color} />}
        </QueryView>
      </Card>
      <Card>
        <CardHeader eyebrow={rangeLabel(range.from, range.to)} title="Top merchants" />
        <QueryView
          query={merchantsQ}
          loading={<LoadingRows rows={5} />}
          isEmpty={(d) => d.groups.length === 0}
          empty={<EmptyState title="No merchants in this range">Purchases in this category appear here.</EmptyState>}
        >
          {(d) => <Merchants data={d} param={param} range={range} color={color} />}
        </QueryView>
      </Card>
    </div>
  );
}

function Trend({ data, color }: { data: SpendBreakdown; color: string }) {
  const bars = data.series.map((s) => ({
    key: s.month,
    label: shortMonth(`${s.month}-01`),
    longLabel: formatMonth(`${s.month}-01`),
    value: s.total,
  }));
  return <MonthBars bars={bars} color={color} className="px-5 pb-5" />;
}

function Merchants({ data, param, range, color }: { data: SpendBreakdown; param: string; range: DateRange; color: string }) {
  const top = data.groups[0]?.share ?? null;
  return (
    <ul className="divide-y divide-border border-t border-border">
      {data.groups.map((g) => {
        const to = merchantActivitySearch(g, param, range);
        const ratio = displayRatio(g.share, top);
        const body = (
          <>
            <div className="min-w-0 flex-1">
              <div className="flex items-baseline justify-between gap-3">
                <span className={g.key.startsWith("__") ? "truncate text-sm text-muted" : "truncate text-sm text-ink"}>{g.label}</span>
                <Money value={g.total} total className="text-sm text-ink" />
              </div>
              <div className="mt-1.5 flex items-center gap-3">
                <div className="h-1 flex-1 overflow-hidden rounded-pill bg-surface-3">
                  <div className="h-full rounded-pill" style={{ width: `${Math.max(2, Math.min(1, ratio ?? 0) * 100)}%`, background: color }} />
                </div>
                <span className="w-12 text-right text-[12px] text-muted tabular">{formatPercent(g.share, Number(g.share) < 0.1 ? 1 : 0)}</span>
              </div>
            </div>
            {to ? <ChevronRight className="size-4 shrink-0 text-subtle transition-transform group-hover:translate-x-0.5" aria-hidden /> : <span className="size-4 shrink-0" />}
          </>
        );
        return (
          <li key={g.key}>
            {to ? (
              <Link to="/activity" search={to} className="group flex items-center gap-3 px-5 py-3 transition-colors hover:bg-surface-2" title={`See ${g.label} in Activity`}>
                {body}
              </Link>
            ) : (
              <div className="flex items-center gap-3 px-5 py-3">{body}</div>
            )}
          </li>
        );
      })}
    </ul>
  );
}
