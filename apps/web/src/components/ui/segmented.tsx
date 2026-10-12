import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

// Its own module, free of Radix, so /signin's theme toggle doesn't pull Radix in (WEB-11).

/** Small segmented control for 2–5 options. */
export function Segmented<V extends string>({
  value,
  onChange,
  options,
  ariaLabel,
  className,
}: {
  value: V;
  onChange: (v: V) => void;
  options: { value: V; label: ReactNode }[];
  ariaLabel: string;
  className?: string;
}) {
  return (
    <div role="radiogroup" aria-label={ariaLabel} className={cn("inline-flex rounded-md border border-border bg-surface-2 p-0.5", className)}>
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="radio"
          aria-checked={value === o.value}
          onClick={() => onChange(o.value)}
          className={cn(
            "tap h-7 rounded-[5px] px-2.5 text-[13px] whitespace-nowrap transition-colors",
            value === o.value ? "bg-surface text-ink shadow-[0_1px_0_var(--color-border)]" : "text-muted hover:text-ink",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}
