import { Area, AreaChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { BalancePoint } from "@/lib/wealth";
import { formatDate } from "@/lib/dates";
import { formatTotal } from "@/lib/money";
import { AXIS_TICK, GRID_STROKE, axisMoney } from "@/components/charts/chart-tooltip";

/**
 * An account's end-of-day balance (bank_balance_series). A null day is a gap (no balance known
 * yet), never a zero. Plotted values are the server's balances, converted for drawing only.
 */
export function BalanceChart({ points, currency, className = "h-44" }: { points: BalancePoint[]; currency: string; className?: string }) {
  return (
    <div className={className}>
      <ResponsiveContainer width="100%" height="100%">
        <AreaChart data={points} margin={{ top: 8, right: 8, left: 4, bottom: 0 }}>
          <defs>
            <linearGradient id="balance-fill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="var(--color-accent)" stopOpacity={0.22} />
              <stop offset="100%" stopColor="var(--color-accent)" stopOpacity={0} />
            </linearGradient>
          </defs>
          <CartesianGrid vertical={false} stroke={GRID_STROKE} />
          <XAxis
            dataKey="date"
            tickFormatter={(d: string) => formatDate(d, "short")}
            tick={AXIS_TICK}
            axisLine={false}
            tickLine={false}
            minTickGap={36}
          />
          <YAxis tickFormatter={axisMoney} tick={AXIS_TICK} axisLine={false} tickLine={false} width={44} domain={["auto", "auto"]} />
          <Tooltip
            cursor={{ stroke: "var(--color-border-strong)" }}
            content={({ active, payload }) => {
              const p = active ? (payload?.[0]?.payload as BalancePoint | undefined) : undefined;
              if (!p) return null;
              return (
                <div className="rounded-md border border-border bg-surface px-3 py-2 text-[12px] shadow-[0_8px_24px_-12px_var(--color-border-strong)]">
                  <p className="font-medium text-ink">{formatDate(p.date)}</p>
                  <p className="tabular mt-0.5 text-ink-2">{p.balance === null ? "No balance known yet" : formatTotal(p.balance, { currency })}</p>
                </div>
              );
            }}
          />
          <Area
            type="stepAfter"
            dataKey="balance"
            stroke="var(--color-accent)"
            strokeWidth={1.75}
            fill="url(#balance-fill)"
            connectNulls={false}
            isAnimationActive={false}
            dot={false}
            activeDot={{ r: 3, fill: "var(--color-accent)", stroke: "var(--color-surface)" }}
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}
