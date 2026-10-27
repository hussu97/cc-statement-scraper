import { CartesianGrid, Line, LineChart, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { NoteLevel } from "@/data/notes";
import { levelLabel, pct, seriesRows } from "@/lib/notes";
import { formatDate } from "@/lib/dates";
import { AXIS_TICK, GRID_STROKE } from "@/components/charts/chart-tooltip";

const COLORS = ["var(--chart-cat-1)", "var(--chart-cat-3)", "var(--chart-cat-6)", "var(--chart-cat-9)", "var(--chart-cat-12)", "var(--chart-cat-14)"];
const LEVEL_STROKE: Record<string, string> = {
  autocall: "var(--color-positive)",
  coupon: "var(--color-warn)",
  break_even: "var(--color-danger)",
  final: "var(--color-border-strong)",
};

/** Each share since the strike as % of its initial level, with the levels that matter drawn across. */
export function NoteChart({ series, levels, className = "h-64" }: { series: Record<string, [string, string][]>; levels: NoteLevel[] | null; className?: string }) {
  const rows = seriesRows(series);
  const symbols = Object.keys(series);
  return (
    <div className={className}>
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={rows} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
          <CartesianGrid vertical={false} stroke={GRID_STROKE} />
          <XAxis dataKey="date" tickFormatter={(d: string) => formatDate(d, "short")} tick={AXIS_TICK} axisLine={false} tickLine={false} minTickGap={36} />
          <YAxis tickFormatter={(v: number) => `${v}%`} tick={AXIS_TICK} axisLine={false} tickLine={false} width={44} domain={["auto", "auto"]} />
          {(levels ?? [])
            .filter((l) => l.kind !== "final")
            .map((l) => (
              <ReferenceLine key={`${l.kind}-${l.pct}`} y={Number(l.pct)} stroke={LEVEL_STROKE[l.kind]} strokeDasharray="4 4" ifOverflow="extendDomain" />
            ))}
          <ReferenceLine y={100} stroke="var(--color-border-strong)" />
          <Tooltip
            cursor={{ stroke: "var(--color-border-strong)" }}
            content={({ active, payload, label }) =>
              active && payload?.length ? (
                <div className="min-w-36 rounded-md border border-border bg-surface px-3 py-2 text-[12px] shadow-[0_8px_24px_-12px_var(--color-border-strong)]">
                  <p className="mb-1.5 font-medium text-ink">{formatDate(String(label))}</p>
                  <ul className="flex flex-col gap-1">
                    {payload.map((p) => (
                      <li key={String(p.dataKey)} className="flex items-center gap-2">
                        <span aria-hidden className="inline-block size-2 shrink-0 rounded-pill" style={{ background: String(p.color) }} />
                        <span className="flex-1 text-ink-2">{String(p.dataKey)}</span>
                        <span className="tabular text-ink">{pct(String(p.value))}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              ) : null
            }
          />
          {symbols.map((s, i) => (
            <Line key={s} type="monotone" dataKey={s} stroke={COLORS[i % COLORS.length]} strokeWidth={1.75} dot={false} connectNulls isAnimationActive={false} />
          ))}
        </LineChart>
      </ResponsiveContainer>
      <ul className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[12px] text-muted">
        {symbols.map((s, i) => (
          <li key={s} className="inline-flex items-center gap-1.5">
            <span className="size-2 rounded-full" style={{ background: COLORS[i % COLORS.length] }} /> {s}
          </li>
        ))}
        {(levels ?? [])
          .filter((l) => l.kind !== "final")
          .map((l) => (
            <li key={`${l.kind}-${l.pct}`} className="inline-flex items-center gap-1.5">
              <span className="h-0 w-3 border-t-2 border-dashed" style={{ borderColor: LEVEL_STROKE[l.kind] }} /> {levelLabel(l)} {pct(l.pct)}
            </li>
          ))}
      </ul>
    </div>
  );
}
