import { cn } from "@/lib/cn";
import { sparkLine } from "./spark";

// The drawing box; the SVG stretches to its container, the stroke keeps its width.
const W = 120;
const H = 32;

/**
 * A hand-rolled sparkline (no chart library on Cards). `label` is its accessible name: say what
 * the line shows, with the first and last values. The end dot marks the latest value.
 */
export function Sparkline({
  values,
  color,
  label,
  min,
  max,
  className,
}: {
  values: (number | null)[];
  color: string;
  label: string;
  min?: number;
  max?: number;
  className?: string;
}) {
  const { line, last } = sparkLine(values, W, H, { min, max, pad: 3 });
  return (
    <div role="img" aria-label={label} className={cn("relative h-8 w-full", className)}>
      {line && (
        <svg aria-hidden viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" className="absolute inset-0 size-full overflow-visible">
          <path d={line} fill="none" stroke={color} strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
        </svg>
      )}
      {last && (
        <span
          aria-hidden
          className="absolute size-1.5 -translate-x-1/2 -translate-y-1/2 rounded-pill ring-2 ring-surface"
          style={{ left: `${(last.x / W) * 100}%`, top: `${(last.y / H) * 100}%`, background: color }}
        />
      )}
    </div>
  );
}
