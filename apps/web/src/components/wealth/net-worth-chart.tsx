import { CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { NetWorthPoint } from "@/lib/wealth";
import { formatDate, formatMonth } from "@/lib/dates";
import { formatTotal } from "@/lib/money";
import { AXIS_TICK, GRID_STROKE, axisMoney } from "@/components/charts/chart-tooltip";

/**
 * Net worth month by month (net_worth_series): each month's last nightly snapshot, ending with
 * today's live figure. Plotted values are the server's, converted for drawing only.
 */
export function NetWorthChart({ points, className = "h-52" }: { points: NetWorthPoint[]; className?: string }) {
  return (
    <div className={className}>
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={points} margin={{ top: 8, right: 12, left: 4, bottom: 0 }}>
          <CartesianGrid vertical={false} stroke={GRID_STROKE} />
          <XAxis dataKey="month" tickFormatter={(m: string) => formatMonth(m, "short")} tick={AXIS_TICK} axisLine={false} tickLine={false} />
          <YAxis tickFormatter={axisMoney} tick={AXIS_TICK} axisLine={false} tickLine={false} width={48} domain={["auto", "auto"]} />
          <Tooltip
            cursor={{ stroke: "var(--color-border-strong)" }}
            content={({ active, payload }) => {
              const p = active ? (payload?.[0]?.payload as NetWorthPoint | undefined) : undefined;
              if (!p) return null;
              return (
                <div className="min-w-44 rounded-md border border-border bg-surface px-3 py-2 text-[12px] shadow-[0_8px_24px_-12px_var(--color-border-strong)]">
                  <p className="font-medium text-ink">{p.is_live ? "Today" : `${formatMonth(p.month)} (on ${formatDate(p.as_of, "short")})`}</p>
                  <dl className="mt-1 grid grid-cols-[1fr_auto] gap-x-3 gap-y-0.5">
                    <dt className="text-ink-2">Net worth</dt>
                    <dd className="tabular text-right text-ink">{formatTotal(p.net)}</dd>
                    <dt className="text-muted">Cash</dt>
                    <dd className="tabular text-right text-muted">{formatTotal(p.cash)}</dd>
                    {p.holdings !== null && p.holdings !== 0 && (
                      <>
                        <dt className="text-muted">Investments</dt>
                        <dd className="tabular text-right text-muted">{formatTotal(p.holdings)}</dd>
                      </>
                    )}
                    <dt className="text-muted">Owed on cards</dt>
                    <dd className="tabular text-right text-muted">{formatTotal(p.owed)}</dd>
                  </dl>
                  {!p.complete && <p className="mt-1 text-[11px] text-warn">Some balances were missing</p>}
                </div>
              );
            }}
          />
          <Line
            type="linear"
            dataKey="net"
            stroke="var(--color-accent)"
            strokeWidth={2}
            isAnimationActive={false}
            dot={{ r: 3, fill: "var(--color-accent)", stroke: "var(--color-surface)", strokeWidth: 1.5 }}
            activeDot={{ r: 4 }}
            connectNulls={false}
          />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}
