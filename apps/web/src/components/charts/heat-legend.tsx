import { heatFill } from "./palette";

/** "Less ▢▢▢▢▢ More" swatch row for heatmaps. */
export function HeatLegend({ levels = 4 }: { levels?: number }) {
  return (
    <div className="flex items-center gap-1.5 text-[11px] text-subtle" aria-hidden>
      <span>Less</span>
      {Array.from({ length: levels + 1 }, (_, l) => (
        <span key={l} className="inline-block size-2.5 rounded-[3px] border border-border/60" style={{ background: heatFill(l, levels) }} />
      ))}
      <span>More</span>
    </div>
  );
}
