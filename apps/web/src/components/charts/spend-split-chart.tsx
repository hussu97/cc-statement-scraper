import { useId, useMemo, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { TooltipContentProps } from "recharts";
import type { NameType, ValueType } from "recharts/types/component/DefaultTooltipContent";
import { useSpendBreakdown } from "@/data/analytics";
import { formatMonth, type DateRange } from "@/lib/dates";
import type { TrendFilters } from "@/lib/trend-filters";
import { formatPercent, formatTotal } from "@/lib/money";
import { useMediaQuery } from "@/lib/hooks";
import { cn } from "@/lib/cn";
import { Segmented } from "@/components/ui/primitives";
import { EmptyState, ErrorState, LoadingBlock } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { AXIS_TICK, CURSOR_FILL, GRID_STROKE, axisMoney } from "./chart-tooltip";
import { shortMonth } from "./heat";
import { breakdownGroupFor, groupActivitySearch, monthDate, monthShare, SPLIT_LABEL, SPLITS, splitChart, type SplitChart, type SpendSplit } from "./spend-split";
import { axisTickInterval } from "@/components/insights/labels";

/** The split control: none / category / bank / merchant. */
export function SplitControl({ value, onChange, className }: { value: SpendSplit; onChange: (s: SpendSplit) => void; className?: string }) {
  return <Segmented ariaLabel="Split bars by" value={value} onChange={onChange} options={SPLITS.map((s) => ({ value: s, label: SPLIT_LABEL[s] }))} className={className} />;
}

/**
 * Monthly spend bars, optionally stacked by category, bank or merchant (top 10
 * plus "Others"), with a totals list under the chart. Every amount and share
 * comes from spend_breakdown (CLAUDE.md §2.2). `filters` narrows it (Insights
 * Trends); `empty` replaces the default empty state, e.g. to say a filter
 * combination matched nothing.
 */
export function SpendSplitChart({
  profileCode,
  range,
  split,
  height = "h-64 md:h-72",
  filters,
  empty,
}: {
  profileCode: string;
  range: DateRange;
  split: SpendSplit;
  height?: string;
  filters?: TrendFilters;
  empty?: ReactNode;
}) {
  const groupBy = breakdownGroupFor(split);
  const q = useSpendBreakdown(profileCode, range, groupBy, undefined, filters);
  const chart = useMemo(() => (q.data ? splitChart(q.data, split) : null), [q.data, split]);
  if (q.isLoading) return <LoadingBlock className={height} />;
  if (q.isError || !chart) return <ErrorState error={q.error} onRetry={() => void q.refetch()} />;
  if (chart.empty)
    return empty ?? (
      <EmptyState title="No spending in this range" className={height}>
        Pick a longer range, or check that your cards are syncing.
      </EmptyState>
    );
  return (
    <div className={cn("transition-opacity", q.isFetching && q.isPlaceholderData && "opacity-70")}>
      <Bars chart={chart} height={height} split={split} />
      <Totals chart={chart} split={split} groupBy={groupBy} range={range} total={q.data!.total} />
    </div>
  );
}

function Bars({ chart, height, split }: { chart: SplitChart; height: string; split: SpendSplit }) {
  const wide = useMediaQuery("(min-width: 768px)");
  const last = chart.series.length - 1;
  const titleId = useId();
  return (
    <figure aria-labelledby={titleId} className={cn("px-1 [&_:focus]:outline-none [&_:focus-visible]:outline-2 [&_:focus-visible]:outline-offset-2 [&_:focus-visible]:outline-focus", height)}>
      <figcaption id={titleId} className="sr-only">
        Monthly spend{split === "none" ? "" : ` by ${SPLIT_LABEL[split].toLowerCase()}`}. The table below lists the totals.
      </figcaption>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={chart.rows} margin={{ top: 8, right: 8, left: 0, bottom: 0 }} barCategoryGap="22%" accessibilityLayer>
          <CartesianGrid vertical={false} stroke={GRID_STROKE} />
          <XAxis
            dataKey="month"
            tickFormatter={(m: string) => shortMonth(monthDate(m))}
            tick={AXIS_TICK}
            axisLine={false}
            tickLine={false}
            interval={axisTickInterval(chart.rows.length, wide ? 14 : 7)}
          />
          <YAxis tickFormatter={axisMoney} tick={AXIS_TICK} axisLine={false} tickLine={false} width={44} />
          <Tooltip cursor={CURSOR_FILL} content={(p) => <SplitTooltip {...p} chart={chart} />} />
          {chart.series.map((s, i) => (
            <Bar key={s.dataKey} dataKey={s.dataKey} name={s.label} stackId="spend" fill={s.fill} maxBarSize={44} radius={i === last ? [3, 3, 0, 0] : 0} isAnimationActive={false} />
          ))}
        </BarChart>
      </ResponsiveContainer>
    </figure>
  );
}

function SplitTooltip({ active, payload, label, chart }: Partial<TooltipContentProps<ValueType, NameType>> & { chart: SplitChart }) {
  if (!active || !payload?.length) return null;
  const month = String(label ?? "");
  const raw = chart.raw.get(month);
  const monthTotal = chart.rows.find((r) => r.month === month)?.monthTotal;
  const rows = chart.series
    .map((s) => ({ s, value: raw?.get(s.dataKey) }))
    .filter((r) => r.value !== undefined && Number(r.value) !== 0)
    .reverse();
  return (
    <div className="min-w-48 max-w-72 rounded-md border border-border bg-surface px-3 py-2 text-[12px] shadow-[0_8px_24px_-12px_var(--color-border-strong)]">
      <p className="mb-1.5 flex items-baseline justify-between gap-3 font-medium text-ink">
        <span>{formatMonth(monthDate(month))}</span>
        <span className="tabular">{formatTotal(monthTotal)}</span>
      </p>
      {chart.series.length > 1 && (
        <ul className="flex flex-col gap-1">
          {rows.map(({ s, value }) => {
            const share = monthShare(value, monthTotal);
            return (
              <li key={s.dataKey} className="flex items-center gap-2">
                <span aria-hidden className="inline-block size-2 shrink-0 rounded-pill" style={{ background: s.fill }} />
                <span className="min-w-0 flex-1 truncate text-ink-2">{s.label}</span>
                <span className="tabular text-ink">{formatTotal(value)}</span>
                <span className="tabular w-9 text-right text-muted">{share !== null ? formatPercent(share) : ""}</span>
              </li>
            );
          })}
          {rows.length === 0 && <li className="text-muted">No spend this month.</li>}
        </ul>
      )}
    </div>
  );
}

function Totals({ chart, split, groupBy, range, total }: { chart: SplitChart; split: SpendSplit; groupBy: ReturnType<typeof breakdownGroupFor>; range: DateRange; total: string }) {
  if (split === "none") {
    return (
      <table className="mt-3 w-full text-[13px]">
        <caption className="sr-only">Spend per month</caption>
        <thead>
          <tr className="text-[11px] tracking-wide text-subtle uppercase">
            <th scope="col" className="px-2 py-1.5 text-left font-medium">Month</th>
            <th scope="col" className="px-2 py-1.5 text-right font-medium">Spend</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-border border-y border-border">
          {[...chart.rows].reverse().map((r) => (
            <tr key={r.month}>
              <th scope="row" className="px-2 py-1.5 text-left font-normal text-ink">{formatMonth(monthDate(r.month))}</th>
              <td className="tabular px-2 py-1.5 text-right whitespace-nowrap text-ink">{formatTotal(r.monthTotal)}</td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr>
            <th scope="row" className="px-2 py-1.5 text-left font-medium text-ink">Total</th>
            <td className="tabular px-2 py-1.5 text-right whitespace-nowrap font-medium text-ink">{formatTotal(total)}</td>
          </tr>
        </tfoot>
      </table>
    );
  }
  return (
    <table className="mt-3 w-full table-fixed text-[13px]">
      <caption className="sr-only">Spend by {SPLIT_LABEL[split].toLowerCase()} for the range, with each one's share</caption>
      <thead>
        <tr className="text-[11px] tracking-wide text-subtle uppercase">
          <th scope="col" className="px-2 py-1.5 text-left font-medium">{SPLIT_LABEL[split]}</th>
          <th scope="col" className="w-[7.5rem] px-2 py-1.5 text-right font-medium md:w-36">Total</th>
          <th scope="col" className="w-14 px-2 py-1.5 text-right font-medium">Share</th>
        </tr>
      </thead>
      <tbody className="divide-y divide-border border-y border-border">
        {chart.series.map((s) => {
          const link = groupActivitySearch(groupBy, s.key, range.from, range.to);
          const name = (
            <span className="flex min-w-0 items-center gap-2">
              <span aria-hidden className="inline-block size-2.5 shrink-0 rounded-[3px]" style={{ background: s.fill }} />
              {split === "bank" && s.key !== "__other__" && <BankLogo bankCode={s.key} size="xs" decorative />}
              <span className="truncate">{s.label}</span>
            </span>
          );
          return (
            <tr key={s.dataKey}>
              <th scope="row" className="px-2 py-1.5 text-left font-normal text-ink">
                {link ? (
                  <Link to="/activity" search={link} className="block min-w-0 hover:text-accent hover:underline">
                    {name}
                  </Link>
                ) : (
                  name
                )}
              </th>
              <td className="tabular px-2 py-1.5 text-right whitespace-nowrap text-ink">{formatTotal(s.total)}</td>
              <td className="tabular px-2 py-1.5 text-right whitespace-nowrap text-muted">{formatPercent(s.share)}</td>
            </tr>
          );
        })}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" className="px-2 py-1.5 text-left font-medium text-ink">Total</th>
          <td className="tabular px-2 py-1.5 text-right whitespace-nowrap font-medium text-ink">{formatTotal(total)}</td>
          <td />
        </tr>
      </tfoot>
    </table>
  );
}
