import { useMemo, useState } from "react";
import { Clock } from "lucide-react";
import { useHourWeekday } from "@/data/analytics";
import type { RpcReturn } from "@/lib/supabase";
import { WEEKDAYS_ISO, type DateRange } from "@/lib/dates";
import { formatMoney, toAmount } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { EmptyState, LoadingBlock, QueryView } from "@/components/ui/states";
import { heatLevel, hourMatrix, quantileThresholds } from "@/components/charts/heat";
import { heatFill } from "@/components/charts/palette";
import { HeatLegend } from "@/components/charts/heat-legend";
import { countLabel, rangeLabel } from "./labels";

type Row = RpcReturn<"hour_weekday_pattern">[number];

const HOURS = Array.from({ length: 24 }, (_, h) => h);
const pad = (h: number) => String(h).padStart(2, "0");
const WEEKDAY_LONG = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

export function TimeOfDayTab({ profileCode, range }: { profileCode: string; range: DateRange }) {
  const q = useHourWeekday(profileCode, range);
  return (
    <Card>
      <CardHeader eyebrow={rangeLabel(range.from, range.to)} title="When you spend" />
      <QueryView
        query={q}
        loading={<LoadingBlock className="h-64" />}
        isEmpty={(rows) => rows.length === 0}
        empty={
          <EmptyState icon={<Clock />} title="No timed transactions in this range">
            Only purchases seen by a bank SMS carry an exact time. Statement-only transactions have a date but no time, so they can't appear here.
          </EmptyState>
        }
      >
        {(rows) => <HourHeatmap rows={rows} />}
      </QueryView>
    </Card>
  );
}

function HourHeatmap({ rows }: { rows: Row[] }) {
  const { matrix, thresholds } = useMemo(
    () => ({ matrix: hourMatrix(rows), thresholds: quantileThresholds(rows.map((r) => toAmount(r.amount) ?? 0)) }),
    [rows],
  );
  const [selected, setSelected] = useState<Row | null>(null);

  return (
    <div className="px-5 pb-5">
      <div className="overflow-x-auto pb-2">
        <div
          className="grid min-w-[480px] gap-[3px]"
          style={{ gridTemplateColumns: "auto repeat(24, minmax(14px, 1fr))" }}
          role="group"
          aria-label="Spending by weekday and hour"
        >
          <span />
          {HOURS.map((h) => (
            <span key={h} className="text-center text-[10px] leading-4 text-subtle tabular">
              {h % 3 === 0 ? pad(h) : ""}
            </span>
          ))}
          {matrix.map((cells, d) => (
            <HourRow key={d} day={d} cells={cells} thresholds={thresholds} selected={selected} onSelect={setSelected} />
          ))}
        </div>
      </div>
      <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
        <p className="min-h-5 text-[13px] text-ink-2" aria-live="polite">
          {selected ? (
            <>
              <span className="font-medium text-ink">
                {WEEKDAY_LONG[selected.dow - 1]}, {pad(selected.hour)}:00–{pad((selected.hour + 1) % 24)}:00
              </span>
              {" · "}
              <span className="tabular">{formatMoney(selected.amount)}</span>
              {" · "}
              {countLabel(selected.txn_count, "transaction")}
            </>
          ) : (
            <span className="text-muted">Times are in Dubai. Point at a cell for details.</span>
          )}
        </p>
        <HeatLegend />
      </div>
      <p className="mt-3 text-[12px] text-subtle">
        Only purchases seen by a bank SMS carry an exact time, so statement-only transactions aren't counted here.
      </p>
    </div>
  );
}

function HourRow({
  day,
  cells,
  thresholds,
  selected,
  onSelect,
}: {
  day: number;
  cells: (Row | null)[];
  thresholds: number[];
  selected: Row | null;
  onSelect: (r: Row | null) => void;
}) {
  return (
    <>
      <span className="pr-1.5 text-right text-[11px] leading-[22px] text-subtle">{WEEKDAYS_ISO[day]}</span>
      {cells.map((c, h) => {
        const label = `${WEEKDAY_LONG[day]} ${pad(h)}:00: ${formatMoney(c?.amount ?? 0)}`;
        return (
          <button
            key={h}
            type="button"
            title={label}
            aria-label={`${label}, ${countLabel(c?.txn_count ?? 0, "transaction")}`}
            className={cn(
              "h-[22px] rounded-[3px] outline-offset-1 hover:outline hover:outline-1 hover:outline-border-strong",
              selected && c && selected.dow === c.dow && selected.hour === c.hour && "outline outline-2 outline-ink",
            )}
            style={{ background: heatFill(heatLevel(toAmount(c?.amount) ?? 0, thresholds)) }}
            onMouseEnter={() => c && onSelect(c)}
            onFocus={() => c && onSelect(c)}
            onClick={() => onSelect(c)}
          />
        );
      })}
    </>
  );
}
