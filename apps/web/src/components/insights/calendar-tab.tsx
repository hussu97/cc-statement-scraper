import { useMemo, useState } from "react";
import { Link } from "@tanstack/react-router";
import { useDailySpend } from "@/data/analytics";
import type { RpcReturn } from "@/lib/supabase";
import { formatDate, WEEKDAYS_ISO, type DateRange } from "@/lib/dates";
import { formatMoney, toAmount } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { EmptyState, LoadingBlock, QueryView } from "@/components/ui/states";
import { buildCalendar, heatLevel, quantileThresholds } from "@/components/charts/heat";
import { heatFill } from "@/components/charts/palette";
import { HeatLegend } from "@/components/charts/heat-legend";
import { allZero, countLabel, rangeLabel } from "./labels";

type Row = RpcReturn<"daily_spend">[number];

export function CalendarTab({ profileCode, range }: { profileCode: string; range: DateRange }) {
  const q = useDailySpend(profileCode, range);
  return (
    <Card>
      <CardHeader eyebrow={rangeLabel(range.from, range.to)} title="Daily spending" />
      <QueryView
        query={q}
        loading={<LoadingBlock className="h-52" />}
        isEmpty={(rows) => rows.length === 0 || allZero(rows.map((r) => r.amount))}
        empty={<EmptyState title="No spending in this range">Pick a longer range to see your spending day by day.</EmptyState>}
      >
        {(rows) => <CalendarHeatmap rows={rows} range={range} />}
      </QueryView>
    </Card>
  );
}

function cellSize(weeks: number): number {
  if (weeks <= 6) return 30;
  if (weeks <= 16) return 20;
  return 13;
}

function CalendarHeatmap({ rows, range }: { rows: Row[]; range: DateRange }) {
  const { layout, thresholds, activeDays } = useMemo(() => {
    const byDate = new Map(rows.map((r) => [r.day, r]));
    const amounts = rows.map((r) => toAmount(r.amount) ?? 0);
    return {
      layout: buildCalendar(range.from, range.to, byDate),
      thresholds: quantileThresholds(amounts),
      activeDays: amounts.filter((a) => a > 0).length,
    };
  }, [rows, range.from, range.to]);
  const [selected, setSelected] = useState<Row | null>(null);
  const size = cellSize(layout.weeks.length);
  const gap = size >= 20 ? 4 : 3;

  return (
    <div className="px-5 pb-5">
      <div
        className="overflow-x-auto pb-2"
        // Start scrolled to the most recent weeks when the grid is wider than the card.
        ref={(el) => {
          if (el) el.scrollLeft = el.scrollWidth;
        }}
      >
        <div
          className="inline-grid"
          style={{
            gridTemplateColumns: `auto repeat(${layout.weeks.length}, ${size}px)`,
            gridTemplateRows: `16px repeat(7, ${size}px)`,
            gap: `${gap}px`,
          }}
          role="group"
          aria-label="Spending per day"
        >
          {/* month labels */}
          <span />
          {layout.weeks.map((w, i) => {
            const m = layout.months.find((x) => x.week === i);
            return (
              <span key={w.start} className="text-[11px] leading-4 whitespace-nowrap text-subtle" style={{ gridRow: 1, gridColumn: i + 2 }}>
                {m?.label ?? ""}
              </span>
            );
          })}
          {/* weekday labels */}
          {WEEKDAYS_ISO.map((d, row) => (
            <span
              key={d}
              className="pr-1.5 text-right text-[11px] text-subtle"
              style={{ gridRow: row + 2, gridColumn: 1, lineHeight: `${size}px` }}
            >
              {row % 2 === 0 ? d : ""}
            </span>
          ))}
          {/* day cells */}
          {layout.weeks.map((w, col) =>
            w.cells.map((c, row) =>
              c ? (
                <button
                  key={c.date}
                  type="button"
                  style={{
                    gridRow: row + 2,
                    gridColumn: col + 2,
                    background: heatFill(heatLevel(toAmount(c.datum?.amount) ?? 0, thresholds)),
                  }}
                  className={cn(
                    "rounded-[3px] border border-transparent transition-[outline] outline-offset-1 hover:outline hover:outline-1 hover:outline-border-strong",
                    selected?.day === c.date && "outline outline-2 outline-ink",
                  )}
                  title={`${formatDate(c.date, "day")}: ${formatMoney(c.datum?.amount ?? 0)}`}
                  aria-label={`${formatDate(c.date, "day")}: ${formatMoney(c.datum?.amount ?? 0)}, ${countLabel(c.datum?.txn_count ?? 0, "transaction")}`}
                  onMouseEnter={() => c.datum && setSelected(c.datum)}
                  onFocus={() => c.datum && setSelected(c.datum)}
                  onClick={() => c.datum && setSelected(c.datum)}
                />
              ) : null,
            ),
          )}
        </div>
      </div>
      <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
        <p className="min-h-5 text-[13px] text-ink-2" aria-live="polite">
          {selected ? (
            <>
              <span className="font-medium text-ink">{formatDate(selected.day, "day")}</span>
              {" · "}
              <span className="tabular">{formatMoney(selected.amount)}</span>
              {" · "}
              {countLabel(selected.txn_count, "transaction")}
              {Number(selected.txn_count) > 0 && (
                <>
                  {" · "}
                  <Link to="/activity" search={{ from: selected.day, to: selected.day }} className="text-accent hover:underline">
                    See transactions
                  </Link>
                </>
              )}
            </>
          ) : (
            <span className="text-muted">
              Spent on {countLabel(activeDays, "day")} of {rows.length}. Point at a day for details.
            </span>
          )}
        </p>
        <HeatLegend />
      </div>
    </div>
  );
}
