import { useMemo, useState } from "react";
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { useYoy } from "@/data/analytics";
import type { RpcReturn } from "@/lib/supabase";
import { todayDubai } from "@/lib/dates";
import { toAmount } from "@/lib/money";
import { Card, CardHeader } from "@/components/ui/display";
import { Select } from "@/components/ui/select";
import { EmptyState, LoadingBlock, QueryView } from "@/components/ui/states";
import { AXIS_TICK, CURSOR_FILL, GRID_STROKE, MoneyTooltip, axisMoney } from "@/components/charts/chart-tooltip";
import { allZero, MONTH_SHORT, yearOptions } from "./labels";

type Row = RpcReturn<"yoy_compare">[number];

const THIS_FILL = "var(--color-accent)";
const LAST_FILL = "var(--chart-uncategorized)";

export function YoyTab({ profileCode }: { profileCode: string }) {
  const currentYear = Number(todayDubai().slice(0, 4));
  const [year, setYear] = useState(currentYear);
  const q = useYoy(profileCode, year);

  return (
    <Card>
      <CardHeader
        title={`${year} against ${year - 1}`}
        eyebrow="Year over year"
        action={
          <Select
            size="sm"
            ariaLabel="Year"
            className="w-24"
            value={String(year)}
            onValueChange={(v) => setYear(Number(v))}
            options={yearOptions(currentYear).map((y) => ({ value: String(y), label: String(y) }))}
          />
        }
      />
      <QueryView
        query={q}
        loading={<LoadingBlock className="h-80" />}
        isEmpty={(rows) => rows.length === 0 || allZero(rows.flatMap((r) => [r.this_year, r.last_year]))}
        empty={
          <EmptyState title={`No spending in ${year} or ${year - 1}`}>Choose another year, or import older statements to compare against.</EmptyState>
        }
      >
        {(rows) => <YoyChart rows={rows} year={year} />}
      </QueryView>
    </Card>
  );
}

function YoyChart({ rows, year }: { rows: Row[]; year: number }) {
  const data = useMemo(
    () =>
      rows.map((r) => ({
        month: MONTH_SHORT[r.month - 1] ?? String(r.month),
        this_year: toAmount(r.this_year) ?? 0,
        last_year: toAmount(r.last_year) ?? 0,
      })),
    [rows],
  );
  const names: Record<string, string> = { this_year: String(year), last_year: String(year - 1) };
  return (
    <div className="px-2 pb-4">
      <div className="h-72 md:h-80">
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={data} margin={{ top: 8, right: 12, left: 4, bottom: 0 }} barGap={2} barCategoryGap="24%">
            <CartesianGrid vertical={false} stroke={GRID_STROKE} />
            <XAxis dataKey="month" tick={AXIS_TICK} axisLine={false} tickLine={false} interval={0} minTickGap={0} />
            <YAxis tickFormatter={axisMoney} tick={AXIS_TICK} axisLine={false} tickLine={false} width={44} />
            <Tooltip cursor={CURSOR_FILL} content={(p) => <MoneyTooltip {...p} nameOf={(k) => names[k] ?? k} formatLabel={(l) => `${l}`} />} />
            <Bar dataKey="last_year" name={names.last_year} fill={LAST_FILL} radius={[3, 3, 0, 0]} maxBarSize={22} isAnimationActive={false} />
            <Bar dataKey="this_year" name={names.this_year} fill={THIS_FILL} radius={[3, 3, 0, 0]} maxBarSize={22} isAnimationActive={false} />
          </BarChart>
        </ResponsiveContainer>
      </div>
      <ul className="mt-3 flex gap-4 px-3 text-[12px] text-ink-2" aria-label="Legend">
        <li className="flex items-center gap-1.5">
          <span aria-hidden className="inline-block size-2 rounded-pill" style={{ background: THIS_FILL }} />
          {year}
        </li>
        <li className="flex items-center gap-1.5">
          <span aria-hidden className="inline-block size-2 rounded-pill" style={{ background: LAST_FILL }} />
          {year - 1}
        </li>
      </ul>
    </div>
  );
}
