import { useMemo } from "react";
import { ChartPie } from "lucide-react";
import { useNetWorth } from "@/data/wealth";
import { allocationSlices } from "@/lib/investments";
import { formatPct } from "@/lib/holdings";
import { formatTotal } from "@/lib/money";
import { Card, CardHeader, Dot } from "@/components/ui/display";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";

/**
 * What net worth is made of (net_worth.allocation): assets by class as one bar with a legend of
 * values and shares, and what the cards owe apart, as a negative. Values and shares are the
 * server's; the bar's widths only draw them.
 */
export function AllocationCard({ profileCode }: { profileCode: string }) {
  const q = useNetWorth(profileCode);
  const slices = useMemo(() => allocationSlices(q.data?.allocation ?? []), [q.data]);
  return (
    <Card>
      <CardHeader eyebrow="Allocation" title="What your net worth is made of" />
      {q.isLoading ? (
        <LoadingRows rows={3} />
      ) : q.isError || !q.data ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : !q.data.allocation ? (
        <EmptyState icon={<ChartPie />} title="Allocation isn't available yet">
          It appears once the server has been updated.
        </EmptyState>
      ) : slices.assets.length === 0 ? (
        <EmptyState icon={<ChartPie />} title="Nothing to split yet">
          Add a bank balance or an investment: this shows how your assets divide between cash, metals, plans, shares and deposits.
        </EmptyState>
      ) : (
        <div className="px-5 pb-5">
          <div className="flex h-3 w-full overflow-hidden rounded-pill bg-surface-3" role="img" aria-label={slices.assets.map((s) => `${s.label} ${formatPct(s.share) ?? ""}`).join(", ")}>
            {slices.assets.map((s) => (
              <span key={s.key} className="h-full border-r border-surface last:border-r-0" style={{ width: `${s.width}%`, background: `var(--chart-${s.token})` }} />
            ))}
          </div>
          <ul className="mt-3 gap-x-8 sm:columns-2">
            {slices.assets.map((s) => (
              <li key={s.key} className="flex break-inside-avoid items-baseline justify-between gap-3 py-1 text-sm">
                <span className="flex min-w-0 items-center gap-2 text-ink-2">
                  <Dot token={s.token} className="size-2.5 self-center" />
                  <span className="truncate">{s.label}</span>
                </span>
                <span className="flex shrink-0 items-baseline gap-2">
                  <span className="tabular text-ink">{formatTotal(s.value)}</span>
                  <span className="tabular w-14 text-right text-[12px] text-subtle">{formatPct(s.share) ?? "—"}</span>
                </span>
              </li>
            ))}
          </ul>
          {slices.owed !== null && (
            <div className="mt-3 flex items-baseline justify-between gap-3 border-t border-border pt-3 text-sm">
              <span className="text-ink-2">Owed on cards</span>
              <span className="flex shrink-0 items-baseline gap-2">
                <span className="tabular text-danger">{formatTotal(slices.owed, { signed: true })}</span>
                <span className="w-14" aria-hidden />
              </span>
            </div>
          )}
          <p className="mt-3 text-[11px] text-subtle">Shares are of your assets. What the cards owe is taken off net worth, not shared out.</p>
        </div>
      )}
    </Card>
  );
}
