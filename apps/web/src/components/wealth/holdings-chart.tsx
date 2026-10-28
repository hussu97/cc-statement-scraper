import { CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { HoldingsPoint } from "@/lib/holdings";
import { formatDate } from "@/lib/dates";
import { formatTotal } from "@/lib/money";
import { AXIS_TICK, GRID_STROKE, axisMoney } from "@/components/charts/chart-tooltip";

const TIP = "min-w-40 rounded-md border border-border bg-surface px-3 py-2 text-[12px] shadow-[0_8px_24px_-12px_var(--color-border-strong)]";

/**
 * What the holdings were worth each day (holdings_value_series) against what had been put in. A
 * day missing some holding's value still plots (complete = false, noted under the chart); a null
 * day is a gap, never a zero. Values are the server's, converted for
 * drawing only.
 */
export function HoldingsValueChart({ points, className = "h-56" }: { points: HoldingsPoint[]; className?: string }) {
  const hasCost = points.some((p) => p.cost !== null);
  return (
    <div className={className}>
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={points} margin={{ top: 8, right: 12, left: 4, bottom: 0 }}>
          <CartesianGrid vertical={false} stroke={GRID_STROKE} />
          <XAxis dataKey="date" tickFormatter={(d: string) => formatDate(d, "short")} tick={AXIS_TICK} axisLine={false} tickLine={false} minTickGap={36} />
          <YAxis tickFormatter={axisMoney} tick={AXIS_TICK} axisLine={false} tickLine={false} width={48} domain={["auto", "auto"]} />
          <Tooltip
            cursor={{ stroke: "var(--color-border-strong)" }}
            content={({ active, payload }) => {
              const p = active ? (payload?.[0]?.payload as HoldingsPoint | undefined) : undefined;
              if (!p) return null;
              return (
                <div className={TIP}>
                  <p className="font-medium text-ink">{formatDate(p.date)}</p>
                  <dl className="mt-1 grid grid-cols-[1fr_auto] gap-x-3 gap-y-0.5">
                    <dt className="text-ink-2">Value</dt>
                    <dd className="tabular text-right text-ink">{p.value === null ? "No value yet" : formatTotal(p.value)}</dd>
                    {!p.complete && p.value !== null && <dd className="col-span-2 text-[11px] text-muted">Part of the total: some holdings had no value</dd>}
                    {p.cost !== null && (
                      <>
                        <dt className="text-muted">Paid</dt>
                        <dd className="tabular text-right text-muted">{formatTotal(p.cost)}</dd>
                      </>
                    )}
                  </dl>
                </div>
              );
            }}
          />
          {hasCost && (
            <Line type="stepAfter" dataKey="cost" name="Paid" stroke="var(--chart-axis)" strokeWidth={1.5} strokeDasharray="4 4" isAnimationActive={false} dot={false} activeDot={false} connectNulls={false} />
          )}
          <Line
            type="linear"
            dataKey="value"
            name="Value"
            stroke="var(--color-accent)"
            strokeWidth={2}
            isAnimationActive={false}
            dot={false}
            activeDot={{ r: 3.5, fill: "var(--color-accent)", stroke: "var(--color-surface)" }}
            connectNulls={false}
          />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}
