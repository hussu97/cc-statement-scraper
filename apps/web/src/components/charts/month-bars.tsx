import { useState } from "react";
import { cn } from "@/lib/cn";
import { formatTotal, toAmount, type MoneyInput } from "@/lib/money";
import { barRatios, labelEvery } from "./spark";

export interface MonthBar {
  key: string;
  /** Axis label ("Oct"). */
  label: string;
  /** Readout and accessible label ("October 2026"). */
  longLabel: string;
  /** Server amount (decimal string or number), shown as is. */
  value: MoneyInput;
}

/**
 * Hand-rolled monthly bars (no chart library on this route): one button per month, so hover,
 * keyboard focus and a tap all select a month and the readout above shows its server amount.
 * Starts on the latest month.
 */
export function MonthBars({ bars, color, className }: { bars: MonthBar[]; color: string; className?: string }) {
  const [picked, setPicked] = useState<number | null>(null);
  const active = picked ?? bars.length - 1;
  const ratios = barRatios(bars.map((b) => toAmount(b.value) ?? 0));
  const showLabel = labelEvery(bars.length, 12);
  const current = bars[active];
  return (
    <div className={className}>
      <p className="flex items-baseline justify-between gap-3 text-[13px]" aria-live="polite">
        <span className="text-muted">{current?.longLabel}</span>
        <span className="tabular font-medium text-ink">{formatTotal(current?.value)}</span>
      </p>
      <div className="mt-3 flex h-40 items-end justify-center gap-[3px] border-b border-border sm:gap-1.5" onMouseLeave={() => setPicked(null)}>
        {bars.map((b, i) => (
          <button
            key={b.key}
            type="button"
            aria-label={`${b.longLabel}: ${formatTotal(b.value)}`}
            aria-pressed={i === active}
            onMouseEnter={() => setPicked(i)}
            onFocus={() => setPicked(i)}
            onClick={() => setPicked(i)}
            className="group flex h-full max-w-16 min-w-0 flex-1 items-end rounded-t-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
          >
            <span
              aria-hidden
              className={cn("block w-full rounded-t-sm transition-opacity", i === active ? "opacity-100" : "opacity-55 group-hover:opacity-80")}
              style={{ height: `${ratios[i]! * 100}%`, background: color }}
            />
          </button>
        ))}
      </div>
      <div aria-hidden className="mt-1.5 flex justify-center gap-[3px] sm:gap-1.5">
        {bars.map((b, i) => (
          <span key={b.key} className={cn("max-w-16 min-w-0 flex-1 truncate text-center text-[11px]", i === active ? "text-ink" : "text-subtle")}>
            {showLabel(i) ? b.label : ""}
          </span>
        ))}
      </div>
    </div>
  );
}
