import { useMemo } from "react";
import { CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { dateTickFormatter, type PortfolioPoint } from "@/lib/broker";
import { formatDate } from "@/lib/dates";
import { formatTotal } from "@/lib/money";
import { AXIS_TICK, GRID_STROKE, axisMoney } from "@/components/charts/chart-tooltip";

const TIP = "min-w-44 rounded-md border border-border bg-surface px-3 py-2 text-[12px] shadow-[0_8px_24px_-12px_var(--color-border-strong)]";

/**
 * A broker portfolio's value each day against the net deposits (broker_portfolio.series). Days
 * rebuilt from the broker's performance index are drawn dashed; daily marks solid. Values are the
 * server's, converted for drawing only.
 */
export function PortfolioChart({ points, currency, className = "h-56" }: { points: PortfolioPoint[]; currency: string; className?: string }) {
  const hasEstimate = points.some((p) => p.isEstimated);
  const tick = useMemo(() => dateTickFormatter(points), [points]);
  return (
    <div className={className}>
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={points} margin={{ top: 8, right: 12, left: 4, bottom: 0 }}>
          <CartesianGrid vertical={false} stroke={GRID_STROKE} />
          <XAxis dataKey="date" tickFormatter={tick} tick={AXIS_TICK} axisLine={false} tickLine={false} minTickGap={48} />
          <YAxis tickFormatter={axisMoney} tick={AXIS_TICK} axisLine={false} tickLine={false} width={48} domain={["auto", "auto"]} />
          <Tooltip
            cursor={{ stroke: "var(--color-border-strong)" }}
            content={({ active, payload }) => {
              const p = active ? (payload?.[0]?.payload as PortfolioPoint | undefined) : undefined;
              if (!p) return null;
              const d = p.day;
              return (
                <div className={TIP}>
                  <p className="font-medium text-ink">
                    {formatDate(d.as_of)}
                    {d.estimated && <span className="font-normal text-muted"> · estimated</span>}
                  </p>
                  <dl className="mt-1 grid grid-cols-[1fr_auto] gap-x-3 gap-y-0.5">
                    <dt className="text-ink-2">Value</dt>
                    <dd className="tabular text-right text-ink">{formatTotal(d.total, { currency })}</dd>
                    {d.cash !== null && (
                      <>
                        <dt className="text-muted">Cash</dt>
                        <dd className="tabular text-right text-muted">{formatTotal(d.cash, { currency })}</dd>
                      </>
                    )}
                    {d.positions !== null && (
                      <>
                        <dt className="text-muted">Positions</dt>
                        <dd className="tabular text-right text-muted">{formatTotal(d.positions, { currency })}</dd>
                      </>
                    )}
                    {d.net_deposits !== null && (
                      <>
                        <dt className="text-muted">Net deposits</dt>
                        <dd className="tabular text-right text-muted">{formatTotal(d.net_deposits, { currency })}</dd>
                      </>
                    )}
                  </dl>
                </div>
              );
            }}
          />
          <Line type="stepAfter" dataKey="deposits" name="Net deposits" stroke="var(--chart-axis)" strokeWidth={1.5} isAnimationActive={false} dot={false} activeDot={false} connectNulls={false} />
          {hasEstimate && (
            <Line
              type="linear"
              dataKey="estimated"
              name="Value (estimated)"
              stroke="var(--color-accent)"
              strokeOpacity={0.6}
              strokeWidth={1.5}
              strokeDasharray="4 3"
              isAnimationActive={false}
              dot={false}
              activeDot={{ r: 3, fill: "var(--color-accent)", stroke: "var(--color-surface)" }}
              connectNulls={false}
            />
          )}
          <Line
            type="linear"
            dataKey="marked"
            name="Value"
            stroke="var(--color-accent)"
            strokeWidth={2}
            isAnimationActive={false}
            dot={points.filter((p) => p.marked !== null).length === 1 ? { r: 3, fill: "var(--color-accent)", stroke: "var(--color-surface)" } : false}
            activeDot={{ r: 3.5, fill: "var(--color-accent)", stroke: "var(--color-surface)" }}
            connectNulls={false}
          />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}
