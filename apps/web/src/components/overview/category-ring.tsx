import { Link } from "@tanstack/react-router";
import { categoryVar } from "@ledger/tokens/chart";
import { displayRatio, formatMoney, formatPercent, toAmount, type MoneyInput } from "@/lib/money";
import { Dot } from "@/components/ui/display";
import { ringDash, ringSegments } from "@/components/charts/ring";
import type { OverviewCategory } from "@/data/overview";

// A hand-rolled SVG ring, so Overview doesn't load the chart library for one donut (WEB-53).
// 180px box, arcs from radius 62 to 86.
const SIZE = 180;
const RADIUS = 74;
const STROKE = 24;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

export function CategoryRing({ categories, total, from, to }: { categories: OverviewCategory[]; total: MoneyInput; from: string; to: string }) {
  const data = categories
    .map((c) => ({ ...c, value: toAmount(c.amount) ?? 0 }))
    .filter((c) => c.value > 0);
  const segments = ringSegments(data.map((c) => c.value));
  const share = (c: OverviewCategory) => formatPercent(displayRatio(c.amount, total));
  // The legend below repeats every value as links; the ring itself is one image with a summary.
  const label = `Top ${data.length} categories of ${formatMoney(total)}: ${data.map((c) => `${c.name ?? "Uncategorised"} ${share(c)}`).join(", ")}`;
  return (
    <div className="grid grid-cols-1 items-center gap-6 sm:grid-cols-[180px_1fr]">
      <div className="relative mx-auto size-[180px]">
        <svg viewBox={`0 0 ${SIZE} ${SIZE}`} className="size-full" role="img" aria-label={label}>
          <g transform={`rotate(-90 ${SIZE / 2} ${SIZE / 2})`} fill="none" strokeWidth={STROKE}>
            {data.map((c, i) => {
              const dash = ringDash(segments[i]!, CIRCUMFERENCE);
              return (
                <circle
                  key={c.category_code ?? "none"}
                  cx={SIZE / 2}
                  cy={SIZE / 2}
                  r={RADIUS}
                  stroke={categoryVar(c.color_token)}
                  strokeDasharray={dash.dasharray}
                  strokeDashoffset={dash.dashoffset}
                />
              );
            })}
          </g>
        </svg>
        <div aria-hidden className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-[11px] text-subtle">Top {data.length}</span>
          <span className="display-num text-lg text-ink">{formatMoney(total, { compact: true })}</span>
        </div>
      </div>
      <ul className="flex flex-col">
        {data.map((c) => (
          <li key={c.category_code ?? "none"}>
            <Link
              to="/activity"
              search={{ category: c.category_code ?? "none", from, to }}
              className="-mx-2 grid grid-cols-[auto_minmax(0,1fr)_auto_auto] items-center gap-3 rounded-sm px-2 py-2.5 text-[13px] hover:bg-surface-2 lg:py-1.5"
            >
              <Dot token={c.color_token} />
              <span className="truncate text-ink">{c.name ?? "Uncategorised"}</span>
              <span className="tabular text-subtle">{share(c)}</span>
              <span className="tabular w-24 text-right text-ink">{formatMoney(c.amount, { whole: true })}</span>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
