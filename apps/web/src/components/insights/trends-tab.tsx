import { useMemo } from "react";
import { useNavigate } from "@tanstack/react-router";
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { insightsRoute } from "@/router";
import { pivotSeries, useSpendSeries, type Grain, type SpendGroup, type SpendSeriesRow } from "@/data/analytics";
import type { DateRange } from "@/lib/dates";
import { DEFAULT_TREND_GROUP, withTrends } from "@/lib/search";
import { Card, CardHeader } from "@/components/ui/display";
import { Segmented } from "@/components/ui/primitives";
import { EmptyState, LoadingBlock, QueryView } from "@/components/ui/states";
import { AXIS_TICK, CURSOR_FILL, GRID_STROKE, MoneyTooltip, axisMoney } from "@/components/charts/chart-tooltip";
import { seriesFill, seriesToken } from "@/components/charts/palette";
import { axisTickInterval, bucketLabel, defaultGrain, rangeLabel } from "./labels";
import { useMediaQuery } from "@/lib/hooks";
import { SpendSplitChart } from "@/components/charts/spend-split-chart";
import { SPLITS, type SpendSplit } from "@/components/charts/spend-split";

function isSplit(g: SpendGroup): g is SpendSplit {
  return (SPLITS as readonly string[]).includes(g);
}

const GROUPS: { value: SpendGroup; label: string }[] = [
  { value: "none", label: "Total" },
  { value: "category", label: "Category" },
  { value: "bank", label: "Bank" },
  { value: "merchant", label: "Merchant" },
  { value: "account", label: "Account" },
  { value: "card", label: "Card" },
];
/** Groups beyond this many fold into "Other" on the server. */
const TOP_GROUPS = 8;

const GRAINS: { value: Grain; label: string }[] = [
  { value: "month", label: "Month" },
  { value: "week", label: "Week" },
  { value: "day", label: "Day" },
];

export function TrendsTab({ profileCode, range }: { profileCode: string; range: DateRange }) {
  // Grouping and bucket size live in the URL (?group=&grain=), like Activity filters.
  const search = insightsRoute.useSearch();
  const navigate = useNavigate({ from: "/insights" });
  const group = search.group ?? DEFAULT_TREND_GROUP;
  // Bank splits come from spend_breakdown, which is monthly.
  const grain = group === "bank" ? "month" : (search.grain ?? defaultGrain(range.from, range.to));
  // Monthly bars split by none / category / bank / merchant use spend_breakdown:
  // top 10 + Others, with the range's totals and shares listed under the chart.
  const split = grain === "month" && isSplit(group) ? group : null;
  const setTrends = (patch: { group?: SpendGroup; grain?: Grain }) =>
    void navigate({ search: (s) => withTrends(s, patch), replace: true });
  const q = useSpendSeries(profileCode, range, grain, group, TOP_GROUPS, split === null);

  return (
    <Card>
      <CardHeader eyebrow={rangeLabel(range.from, range.to)} title="Spending over time" />
      <div className="flex flex-wrap items-center justify-between gap-2 px-5 pb-2">
        <div className="-mx-1 max-w-full overflow-x-auto px-1 [scrollbar-width:none]">
          <Segmented ariaLabel="Group by" value={group} onChange={(g) => setTrends({ group: g })} options={GROUPS} />
        </div>
        <Segmented ariaLabel="Bucket size" value={grain} onChange={(g) => setTrends({ grain: g })} options={group === "bank" ? GRAINS.filter((g) => g.value === "month") : GRAINS} />
      </div>
      {split !== null ? (
        <div className="px-3 pb-4 md:px-4">
          <SpendSplitChart profileCode={profileCode} range={range} split={split} height="h-72 md:h-80" />
        </div>
      ) : (
        <QueryView
          query={q}
          loading={<LoadingBlock className="h-80" />}
          isEmpty={(rows) => rows.length === 0}
          empty={
            <EmptyState title="No spending in this range" className="h-80">
              Pick a longer range, or check that your cards are syncing.
            </EmptyState>
          }
        >
          {(rows) => <TrendsChart rows={rows} grain={grain} byCategory={group === "category"} />}
        </QueryView>
      )}
    </Card>
  );
}

function TrendsChart({ rows, grain, byCategory }: { rows: SpendSeriesRow[]; grain: Grain; byCategory: boolean }) {
  const pivot = useMemo(() => pivotSeries(rows), [rows]);
  const series = useMemo(
    () =>
      pivot.groups.map((g, index) => {
        const token = seriesToken({ key: g.key, colorToken: g.color_token, index, byCategory });
        return { ...g, token, fill: seriesFill(token, g.key) };
      }),
    [pivot.groups, byCategory],
  );
  const labelOf = useMemo(() => new Map(series.map((s) => [s.key, s.label])), [series]);
  const last = series.length - 1;
  const wide = useMediaQuery("(min-width: 768px)");

  return (
    <div className="px-2 pb-4">
      <div className="h-72 md:h-80">
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={pivot.rows} margin={{ top: 8, right: 12, left: 4, bottom: 0 }} barCategoryGap="22%">
            <CartesianGrid vertical={false} stroke={GRID_STROKE} />
            <XAxis
              dataKey="bucket"
              tickFormatter={(b: string) => bucketLabel(b, grain)}
              tick={AXIS_TICK}
              axisLine={false}
              tickLine={false}
              interval={axisTickInterval(pivot.rows.length, wide ? 14 : 7)}
            />
            <YAxis tickFormatter={axisMoney} tick={AXIS_TICK} axisLine={false} tickLine={false} width={44} />
            <Tooltip
              cursor={CURSOR_FILL}
              content={(p) => <MoneyTooltip {...p} formatLabel={(l) => bucketLabel(l, grain, true)} nameOf={(k) => labelOf.get(k) ?? k} />}
            />
            {series.map((s, i) => (
              <Bar
                key={s.key}
                dataKey={s.key}
                name={s.label}
                stackId="spend"
                fill={s.fill}
                maxBarSize={44}
                radius={i === last ? [3, 3, 0, 0] : 0}
                isAnimationActive={false}
              />
            ))}
          </BarChart>
        </ResponsiveContainer>
      </div>
      {series.length > 1 && (
        <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-1.5 px-3" aria-label="Legend">
          {series.map((s) => (
            <li key={s.key} className="flex min-w-0 items-center gap-1.5 text-[12px] text-ink-2">
              <span aria-hidden className="inline-block size-2 shrink-0 rounded-pill" style={{ background: s.fill }} />
              <span className="max-w-48 truncate">{s.label}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
