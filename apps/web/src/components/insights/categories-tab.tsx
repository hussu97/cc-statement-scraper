import { useMemo } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronRight } from "lucide-react";
import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts";
import { useCategoryBreakdown } from "@/data/analytics";
import type { RpcReturn } from "@/lib/supabase";
import type { DateRange } from "@/lib/dates";
import { displayRatio, formatChange, formatMoney, formatPercent, toAmount } from "@/lib/money";
import { UNCATEGORIZED } from "@/lib/activity-filters";
import { Money } from "@/components/ledger";
import { Badge, Card, CardHeader, Dot } from "@/components/ui/display";
import { Tooltip as HoverTip } from "@/components/ui/primitives";
import { EmptyState, LoadingRows, QueryView } from "@/components/ui/states";
import { TooltipCard } from "@/components/charts/chart-tooltip";
import { categoryVar } from "@/components/charts/palette";
import { changeTone, countLabel, rangeLabel } from "./labels";

type Row = RpcReturn<"category_breakdown">[number];

export function CategoriesTab({ profileCode, range }: { profileCode: string; range: DateRange }) {
  const q = useCategoryBreakdown(profileCode, range);
  return (
    <Card>
      <CardHeader eyebrow={rangeLabel(range.from, range.to)} title="Spending by category" />
      <QueryView
        query={q}
        loading={<LoadingRows rows={6} />}
        isEmpty={(rows) => rows.length === 0}
        empty={<EmptyState title="No spending in this range">Pick a longer range to see where your money went.</EmptyState>}
      >
        {(rows) => <Breakdown rows={rows} range={range} />}
      </QueryView>
    </Card>
  );
}

function Breakdown({ rows, range }: { rows: Row[]; range: DateRange }) {
  const data = useMemo(() => rows.map((r) => ({ ...r, value: Math.max(0, toAmount(r.amount) ?? 0) })), [rows]);
  const topShare = rows[0]?.share ?? null;
  return (
    <div className="grid gap-2 pb-3 lg:grid-cols-[280px_1fr] lg:gap-6">
      <div className="mx-auto h-56 w-56 lg:mt-2 lg:h-64 lg:w-64" aria-hidden>
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie data={data} dataKey="value" nameKey="name" innerRadius="64%" outerRadius="96%" paddingAngle={1} stroke="var(--color-surface)" strokeWidth={2} isAnimationActive={false}>
              {data.map((r) => (
                <Cell key={r.category_code ?? UNCATEGORIZED} fill={categoryVar(r.color_token)} />
              ))}
            </Pie>
            <Tooltip
              content={({ active, payload }) => {
                const r = active ? (payload?.[0]?.payload as Row | undefined) : undefined;
                if (!r) return null;
                return (
                  <TooltipCard
                    title={r.name}
                    rows={[{ key: "amt", label: formatPercent(r.share, 1), color: categoryVar(r.color_token), value: r.amount }]}
                  />
                );
              }}
            />
          </PieChart>
        </ResponsiveContainer>
      </div>
      <ul className="divide-y divide-border border-t border-border lg:border-t-0">
        {rows.map((r) => (
          <CategoryRow key={r.category_code ?? UNCATEGORIZED} row={r} range={range} barRatio={displayRatio(r.share, topShare)} />
        ))}
      </ul>
    </div>
  );
}

function CategoryRow({ row, range, barRatio }: { row: Row; range: DateRange; barRatio: number | null }) {
  // Server fraction vs the previous period of the same length; null when that period had no spend.
  const delta = formatChange(row.change);
  const tone = changeTone(row.change);
  const isNew = delta === null;
  return (
    <li>
      <Link
        to="/activity"
        search={{ category: row.category_code ?? UNCATEGORIZED, from: range.from, to: range.to }}
        className="group flex items-center gap-3 px-5 py-3 transition-colors hover:bg-surface-2"
      >
        <Dot token={row.color_token} className="size-2.5" />
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline justify-between gap-3">
            <span className="truncate text-sm text-ink">{row.name}</span>
            <Money value={row.amount} className="text-sm text-ink" />
          </div>
          <div className="mt-1.5 flex items-center gap-3">
            <div className="h-1 flex-1 overflow-hidden rounded-pill bg-surface-3">
              <div
                className="h-full rounded-pill"
                style={{ width: `${Math.max(2, Math.min(1, barRatio ?? 0) * 100)}%`, background: categoryVar(row.color_token) }}
              />
            </div>
            <span className="w-12 text-right text-[12px] text-muted tabular">{formatPercent(row.share, row.share < 0.1 ? 1 : 0)}</span>
            <span className="flex w-16 justify-end">
              {delta ? (
                <HoverTip content={`Previous period: ${formatMoney(row.prev_amount)}`}>
                  <Badge tone={tone === "neutral" ? "neutral" : tone} className="tabular">
                    {delta}
                  </Badge>
                </HoverTip>
              ) : isNew ? (
                <Badge tone="neutral">New</Badge>
              ) : null}
            </span>
          </div>
          <p className="mt-1 text-[12px] text-subtle">{countLabel(row.txn_count, "transaction")}</p>
        </div>
        <ChevronRight className="size-4 shrink-0 text-subtle transition-transform group-hover:translate-x-0.5" aria-hidden />
      </Link>
    </li>
  );
}
