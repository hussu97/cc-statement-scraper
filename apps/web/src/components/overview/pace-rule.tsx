import { formatMoney, type MoneyInput } from "@/lib/money";
import { labelLanes, placeMarks } from "@/lib/pace";
import { cn } from "@/lib/cn";

/**
 * The signature element: this month's spend drawn as ink along a ruled line,
 * with pins where last month stood by today and the 3-month average.
 */
export function PaceRule({ spend, prevToDate, avg3m, dayLabel }: { spend: MoneyInput; prevToDate: MoneyInput; avg3m: MoneyInput; dayLabel: string }) {
  const { marks } = placeMarks([
    { key: "spend", value: spend },
    { key: "prev", value: prevToDate },
    { key: "avg", value: avg3m },
  ]);
  const [s, p, a] = marks;
  const pins = [
    { mark: p!, label: `Last month by ${dayLabel}`, value: prevToDate, tone: "text-ink-2" },
    { mark: a!, label: "3-month average", value: avg3m, tone: "text-muted" },
  ];
  const lanes = labelLanes(pins.map((x) => x.mark.at), 0.3);
  const maxLane = Math.max(0, ...lanes);

  return (
    <figure className="w-full" aria-label="Spending pace this month">
      <div className="relative" style={{ paddingTop: `${(maxLane + 1) * 34}px` }}>
        {pins.map((pin, i) =>
          pin.mark.at === null ? null : (
            <div
              key={pin.mark.key}
              className="absolute flex flex-col"
              style={{
                left: `${pin.mark.at * 100}%`,
                top: `${lanes[i]! * 34}px`,
                bottom: 0,
                transform: pin.mark.at > 0.6 ? "translateX(-100%)" : undefined,
                alignItems: pin.mark.at > 0.6 ? "flex-end" : "flex-start",
              }}
            >
              <span className={cn("text-[11px] leading-tight whitespace-nowrap", pin.tone)}>{pin.label}</span>
              <span className="tabular text-[12px] leading-tight font-medium whitespace-nowrap text-ink">{formatMoney(pin.value, { whole: true })}</span>
              <span className={cn("mt-1 w-px flex-1 bg-border-strong", pin.mark.at > 0.6 ? "self-end" : "self-start")} />
            </div>
          ),
        )}
      </div>
      <div className="ruled relative h-5 pb-1.5">
        <div className="absolute inset-x-0 top-[7px] h-[3px] rounded-pill bg-surface-3" />
        <div
          className="absolute top-[5px] left-0 h-[7px] rounded-pill bg-accent transition-[width] duration-700 ease-out"
          style={{ width: `${(s!.at ?? 0) * 100}%` }}
        />
        {s!.at !== null && <div className="absolute top-0 size-[17px] -translate-x-1/2 rounded-pill border-[3px] border-surface bg-accent" style={{ left: `${s!.at * 100}%` }} />}
      </div>
      <figcaption className="sr-only">
        Spent {formatMoney(spend)} so far; last month by this day {formatMoney(prevToDate)}; three-month average {formatMoney(avg3m)}.
      </figcaption>
    </figure>
  );
}
