import { lazy, Suspense, useState } from "react";
import { Link } from "@tanstack/react-router";
import { addMonths, formatMonth, monthEnd, monthStart } from "@/lib/dates";
import { Card, CardHeader } from "@/components/ui/display";
import { LoadingBlock } from "@/components/ui/states";
import { SplitControl } from "@/components/charts/split-control";
import type { SpendSplit } from "@/components/charts/spend-split";

// The bars are the only chart-library user on Overview: load them after the screen renders,
// so the hero and the category ring don't wait for that chunk (WEB-53).
const SpendSplitChart = lazy(() => import("@/components/charts/spend-split-chart").then((m) => ({ default: m.SpendSplitChart })));

/** Six months up to the Overview's month, as bars that can be split by category, bank or merchant. */
export function MonthlySpendCard({ profileCode, month }: { profileCode: string; month: string }) {
  const [split, setSplit] = useState<SpendSplit>("none");
  const from = addMonths(monthStart(month), -5);
  const to = monthEnd(month);
  return (
    <Card>
      <CardHeader
        eyebrow={`${formatMonth(from, "short")} – ${formatMonth(to)}`}
        title="Monthly spend"
        action={
          <Link to="/insights" search={{ tab: undefined }} className="tap text-[13px] text-accent hover:underline">
            Trends
          </Link>
        }
      />
      <div className="-mt-1 overflow-x-auto px-5 pb-2 [scrollbar-width:none]">
        <SplitControl value={split} onChange={setSplit} />
      </div>
      <div className="px-3 pb-4 md:px-4">
        <Suspense fallback={<LoadingBlock className="h-64 md:h-72" />}>
          <SpendSplitChart profileCode={profileCode} range={{ from, to }} split={split} />
        </Suspense>
      </div>
    </Card>
  );
}
