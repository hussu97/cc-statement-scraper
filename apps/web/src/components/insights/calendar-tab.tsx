import { useMemo, useState } from "react";
import { Link } from "@tanstack/react-router";
import { useDailySpend } from "@/data/analytics";
import { useTransactions } from "@/data/transactions";
import type { RpcReturn } from "@/lib/supabase";
import { formatDate, todayDubai, WEEKDAYS_ISO, type DateRange } from "@/lib/dates";
import { formatMoney, toAmount } from "@/lib/money";
import { useElementWidth } from "@/lib/hooks";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { Sheet } from "@/components/ui/dialog";
import { EmptyState, ErrorState, LoadingBlock, LoadingRows, QueryView } from "@/components/ui/states";
import { TxnAmount } from "@/components/ledger";
import { buildCalendar, calendarEnd, DAY_LABEL_W, fitCalendar, heatLevel, MONTH_LABEL_W, quantileThresholds, type CalendarLayout } from "@/components/charts/heat";
import { heatFill } from "@/components/charts/palette";
import { HeatLegend } from "@/components/charts/heat-legend";
import { allZero, countLabel, rangeLabel } from "./labels";

type Row = RpcReturn<"daily_spend">[number];

export function CalendarTab({ profileCode, range }: { profileCode: string; range: DateRange }) {
  const q = useDailySpend(profileCode, range);
  // Future days are neither drawn nor counted (WEB-15).
  const end = calendarEnd(range.to, todayDubai());
  return (
    <Card>
      <CardHeader eyebrow={range.from <= end ? rangeLabel(range.from, end) : rangeLabel(range.from, range.to)} title="Daily spending" />
      <QueryView
        query={q}
        loading={<LoadingBlock className="h-52" />}
        isEmpty={(rows) => rows.filter((r) => r.day <= end).length === 0 || allZero(rows.filter((r) => r.day <= end).map((r) => r.amount))}
        empty={<EmptyState title="No spending in this range">Pick a longer range to see your spending day by day.</EmptyState>}
      >
        {(rows) => <CalendarHeatmap rows={rows.filter((r) => r.day <= end)} from={range.from} to={end} profileCode={profileCode} />}
      </QueryView>
    </Card>
  );
}

function CalendarHeatmap({ rows, from, to, profileCode }: { rows: Row[]; from: string; to: string; profileCode: string }) {
  const { layout, thresholds, activeDays } = useMemo(() => {
    const byDate = new Map(rows.map((r) => [r.day, r]));
    const amounts = rows.map((r) => toAmount(r.amount) ?? 0);
    return {
      layout: buildCalendar(from, to, byDate),
      thresholds: quantileThresholds(amounts),
      activeDays: amounts.filter((a) => a > 0).length,
    };
  }, [rows, from, to]);
  const [measure, width] = useElementWidth<HTMLDivElement>();
  const fit = fitCalendar(width, layout.weeks.length);
  const [hovered, setHovered] = useState<Row | null>(null);
  const [day, setDay] = useState<Row | null>(null);
  const cell = (c: { date: string; datum: Row | null }) => ({
    background: heatFill(heatLevel(toAmount(c.datum?.amount) ?? 0, thresholds)),
    label: `${formatDate(c.date, "day")}: ${formatMoney(c.datum?.amount ?? 0)}, ${countLabel(c.datum?.txn_count ?? 0, "transaction")}`,
  });
  const onCell = {
    hover: (d: Row | null) => d && setHovered(d),
    open: (d: Row | null) => d && setDay(d),
  };

  return (
    <div className="px-5 pb-5">
      <div ref={measure} className="w-full">
        {width > 0 &&
          (fit.orientation === "horizontal" ? (
            <HorizontalGrid layout={layout} size={fit.size} gap={fit.gap} cell={cell} selected={hovered?.day ?? day?.day} onCell={onCell} />
          ) : (
            <VerticalGrid layout={layout} size={fit.size} gap={fit.gap} cell={cell} selected={day?.day} onCell={onCell} />
          ))}
      </div>
      <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
        <p className="min-h-5 text-[13px] text-ink-2" aria-live="polite">
          {hovered ? (
            <>
              <span className="font-medium text-ink">{formatDate(hovered.day, "day")}</span>
              {" · "}
              <span className="tabular">{formatMoney(hovered.amount)}</span>
              {" · "}
              {countLabel(hovered.txn_count, "transaction")}
            </>
          ) : (
            <span className="text-muted">
              Spent on {countLabel(activeDays, "day")} of {rows.length}.{" "}
              <span className="lg:hidden">Tap a day for its transactions.</span>
              <span className="hidden lg:inline">Click a day for its transactions.</span>
            </span>
          )}
        </p>
        <HeatLegend />
      </div>
      <DaySheet profileCode={profileCode} day={day} onClose={() => setDay(null)} />
    </div>
  );
}

interface GridProps {
  layout: CalendarLayout<Row>;
  size: number;
  gap: number;
  cell: (c: { date: string; datum: Row | null }) => { background: string; label: string };
  selected: string | undefined;
  onCell: { hover: (d: Row | null) => void; open: (d: Row | null) => void };
}

function DayCell({ c, row, col, props }: { c: { date: string; datum: Row | null }; row: number; col: number; props: GridProps }) {
  const { background, label } = props.cell(c);
  return (
    <button
      type="button"
      style={{ gridRow: row, gridColumn: col, background }}
      className={cn(
        "rounded-[3px] border border-transparent transition-[outline] outline-offset-1 hover:outline hover:outline-1 hover:outline-border-strong",
        props.selected === c.date && "outline outline-2 outline-ink",
      )}
      title={label}
      aria-label={label}
      onMouseEnter={() => props.onCell.hover(c.datum)}
      onFocus={() => props.onCell.hover(c.datum)}
      onClick={() => props.onCell.open(c.datum)}
    />
  );
}

/** GitHub-style: a column per week, Monday on top. Desktop and short ranges. */
function HorizontalGrid(props: GridProps) {
  const { layout, size, gap } = props;
  return (
    <div
      className="overflow-x-auto pb-2"
      // Start at the most recent weeks if the grid is still wider than the card.
      ref={(el) => {
        if (el) el.scrollLeft = el.scrollWidth;
      }}
    >
      <div
        className="inline-grid"
        style={{ gridTemplateColumns: `${DAY_LABEL_W - gap}px repeat(${layout.weeks.length}, ${size}px)`, gridTemplateRows: `16px repeat(7, ${size}px)`, gap: `${gap}px` }}
        role="group"
        aria-label="Spending per day"
      >
        <span />
        {layout.weeks.map((w, i) => (
          <span key={w.start} className="text-[11px] leading-4 whitespace-nowrap text-subtle" style={{ gridRow: 1, gridColumn: i + 2 }}>
            {layout.months.find((x) => x.week === i)?.label ?? ""}
          </span>
        ))}
        {WEEKDAYS_ISO.map((d, row) => (
          <span key={d} className="pr-1.5 text-right text-[11px] text-subtle" style={{ gridRow: row + 2, gridColumn: 1, lineHeight: `${size}px` }}>
            {row % 2 === 0 ? d : ""}
          </span>
        ))}
        {layout.weeks.map((w, col) => w.cells.map((c, row) => (c ? <DayCell key={c.date} c={c} row={row + 2} col={col + 2} props={props} /> : null)))}
      </div>
    </div>
  );
}

/** Phones: 7 day columns, a row per week, so cells stay near tap size (WEB-22r). */
function VerticalGrid(props: GridProps) {
  const { layout, size, gap } = props;
  return (
    <div
      className="grid"
      style={{ gridTemplateColumns: `${MONTH_LABEL_W - gap}px repeat(7, ${size}px)`, gridTemplateRows: `16px repeat(${layout.weeks.length}, ${size}px)`, gap: `${gap}px` }}
      role="group"
      aria-label="Spending per day"
    >
      <span />
      {WEEKDAYS_ISO.map((d, i) => (
        <span key={d} className="text-center text-[11px] leading-4 text-subtle" style={{ gridRow: 1, gridColumn: i + 2 }}>
          {d.slice(0, 2)}
        </span>
      ))}
      {layout.weeks.map((w, i) => (
        <span key={w.start} className="text-[11px] text-subtle" style={{ gridRow: i + 2, gridColumn: 1, lineHeight: `${size}px` }}>
          {layout.months.find((x) => x.week === i)?.label ?? ""}
        </span>
      ))}
      {layout.weeks.map((w, wk) => w.cells.map((c, dow) => (c ? <DayCell key={c.date} c={c} row={wk + 2} col={dow + 2} props={props} /> : null)))}
    </div>
  );
}

/** A day's transactions in a sheet: the tap target the tiny grid can't be (WEB-22r). */
function DaySheet({ profileCode, day, onClose }: { profileCode: string; day: Row | null; onClose: () => void }) {
  return (
    <Sheet
      open={!!day}
      onOpenChange={(o) => !o && onClose()}
      title={day ? formatDate(day.day, "day") : "Day"}
      description={day ? `${formatMoney(day.amount)} spent · ${countLabel(day.txn_count, "transaction")}` : undefined}
    >
      {day && <DayTransactions profileCode={profileCode} day={day.day} />}
    </Sheet>
  );
}

/** Mounted only while the sheet is open, so the query runs only then. */
function DayTransactions({ profileCode, day }: { profileCode: string; day: string }) {
  const q = useTransactions(profileCode, { from: day, to: day });
  const rows = q.data?.rows ?? [];
  return (
    <>
      {q.isLoading ? (
        <LoadingRows rows={3} className="p-0" />
      ) : q.isError ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : rows.length === 0 ? (
        <p className="text-[13px] text-muted">No transactions on this day.</p>
      ) : (
        <div className="flex flex-col gap-4">
          <ul className="-mx-2 flex flex-col">
            {rows.map((t) => (
              <li key={t.txn_code}>
                <Link
                  to="/activity"
                  search={{ txn: t.txn_code ?? undefined }}
                  className="flex min-h-11 items-center justify-between gap-3 rounded-md px-2 py-2 hover:bg-surface-2"
                >
                  <span className="min-w-0">
                    <span className="block truncate text-sm text-ink">{t.merchant_name ?? t.description}</span>
                    <span className="block truncate text-[12px] text-muted">
                      {t.category_name ?? "Uncategorised"} · {t.bank_code} •{t.card_last4}
                    </span>
                  </span>
                  <TxnAmount t={t} className="text-sm" />
                </Link>
              </li>
            ))}
          </ul>
          <Link to="/activity" search={{ from: day, to: day }} className="tap self-start text-[13px] text-accent hover:underline">
            Open this day in Activity
          </Link>
        </div>
      )}
    </>
  );
}
