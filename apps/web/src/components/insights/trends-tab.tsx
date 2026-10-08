import { useMemo, useState } from "react";
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { pivotSeries, useSpendSeries, type Grain, type SpendGroup, type SpendSeriesRow } from "@/data/analytics";
import type { DateRange } from "@/lib/dates";
import { Card, CardHeader } from "@/components/ui/display";
import { Segmented } from "@/components/ui/primitives";
import { EmptyState, LoadingBlock, QueryView } from "@/components/ui/states";
import { AXIS_TICK, CURSOR_FILL, GRID_STROKE, MoneyTooltip, axisMoney } from "@/components/charts/chart-tooltip";
import { seriesFill, seriesToken } from "@/components/charts/palette";
import { bucketLabel, defaultGrain, rangeLabel } from "./labels";

const GROUPS: { value: SpendGroup; label: string }[] = [
  { value: "none", label: "Total" },
  { value: "category", label: "Category" },
  { value: "merchant", label: "Merchant" },
  { value: "account", label: "Account" },
  { value: "card", label: "Card" },
];
const GRAINS: { value: Grain; label: string }[] = [
  { value: "month", label: "Month" },
  { value: "week", label: "Week" },
  { value: "day", label: "Day" },
];

export function TrendsTab({ profileCode, range }: { profileCode: string; range: DateRange }) {
  const [group, setGroup] = useState<SpendGroup>("category");
  const [grainPref, setGrain] = useState<Grain | null>(null);
  const grain = grainPref ?? defaultGrain(range.from, range.to);
  const q = useSpendSeries(profileCode, range, grain, group);

  return (
    <Card>
      <CardHeader eyebrow={rangeLabel(range.from, range.to)} title="Spending over time" />
      <div className="flex flex-wrap items-center justify-between gap-2 px-5 pb-2">
        <div className="-mx-1 max-w-full overflow-x-auto px-1 [scrollbar-width:none]">
          <Segmented ariaLabel="Group by" value={group} onChange={setGroup} options={GROUPS} />
        </div>
        <Segmented ariaLabel="Bucket size" value={grain} onChange={setGrain} options={GRAINS} />
      </div>
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
    </Card>
  );
}

function TrendsChart({ rows, grain, byCategory }: { rows: SpendSeriesRow[]; grain: Grain; byCategory: boolean }) {
  const pivot = useMemo(() => pivotSeries(rows, 6), [rows]);
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
              minTickGap={18}
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
