import { formatTotal, type MoneyInput } from "@/lib/money";
import { labelLanes, PIN_FLIP_AT, placeMarks, type PacePin } from "@/lib/pace";
import { cn } from "@/lib/cn";

/**
 * The signature element: this month's spend drawn as ink along a ruled line,
 * with pins where last month and the 3-month average stood by today (WEB-26),
 * and the server's projected month end under it.
 */
export function PaceRule({ spend, pins, projection }: { spend: MoneyInput; pins: PacePin[]; projection: string | null }) {
  const { marks } = placeMarks([{ key: "spend", value: spend }, ...pins.map((p) => ({ key: p.key, value: p.value }))]);
  const [s, ...pinMarks] = marks;
  const tones = ["text-ink-2", "text-muted"];
  const placed = pins.map((pin, i) => ({ ...pin, mark: pinMarks[i]!, tone: tones[i] ?? "text-muted" }));
  // A label is about 150px: half of a phone-width rule (~300px), so it always fits on its side.
  const lanes = labelLanes(placed.map((x) => x.mark.at), 0.5);
  const maxLane = Math.max(0, ...lanes);

  return (
    <figure className="w-full" aria-label="Spending pace this month">
      <div className="relative" style={{ paddingTop: `${(maxLane + 1) * 34}px` }}>
        {placed.map((pin, i) =>
          pin.mark.at === null ? null : (
            <div
              key={pin.key}
              className="absolute flex flex-col"
              style={{
                left: `${pin.mark.at * 100}%`,
                top: `${lanes[i]! * 34}px`,
                bottom: 0,
                transform: pin.mark.at > PIN_FLIP_AT ? "translateX(-100%)" : undefined,
                alignItems: pin.mark.at > PIN_FLIP_AT ? "flex-end" : "flex-start",
              }}
            >
              <span className={cn("text-[11px] leading-tight whitespace-nowrap", pin.tone)}>{pin.label}</span>
              <span className="tabular text-[12px] leading-tight font-medium whitespace-nowrap text-ink">{formatTotal(pin.value)}</span>
              <span className={cn("mt-1 w-px flex-1 bg-border-strong", pin.mark.at > PIN_FLIP_AT ? "self-end" : "self-start")} />
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
      {projection && <p className="tabular mt-2 text-[13px] text-muted">{projection}</p>}
      <figcaption className="sr-only">
        Spent {formatTotal(spend)} so far; {placed.map((p) => `${p.label} ${formatTotal(p.value)}`).join("; ")}.
        {projection ? ` ${projection}.` : ""}
      </figcaption>
    </figure>
  );
}
