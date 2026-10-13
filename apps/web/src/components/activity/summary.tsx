import type { ActivitySummary } from "@/data/transactions";
import { formatDateSpan } from "@/lib/dates";
import { formatCount, formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Skeleton } from "@/components/ui/display";
import { Tooltip } from "@/components/ui/primitives";

/**
 * One line above the Activity list: how many transactions match the filters,
 * their net AED value and the date span. Every figure comes from
 * public.activity_summary (CLAUDE.md §2.2).
 */
export function ActivitySummaryStrip({
  data,
  isLoading,
  isError,
  isFetching,
}: {
  data: ActivitySummary | undefined;
  isLoading: boolean;
  isError: boolean;
  isFetching: boolean;
}) {
  if (isLoading) {
    return (
      <div className="mt-4 flex h-5 items-center" aria-label="Loading summary">
        <Skeleton className="h-3.5 w-72 max-w-full" />
      </div>
    );
  }
  if (isError || !data) {
    return <p className="mt-4 text-sm text-muted">Couldn't load the totals for these filters.</p>;
  }
  const count = data.txn_count;
  const span = count > 0 ? formatDateSpan(data.earliest_date, data.latest_date) : null;
  return (
    <p
      aria-live="polite"
      className={cn("mt-4 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-muted", isFetching && "opacity-70 transition-opacity")}
    >
      <span>
        <span className="tabular font-medium text-ink">{formatCount(count)}</span> {count === 1 ? "transaction" : "transactions"}
      </span>
      {count > 0 && (
        <span className="inline-flex flex-wrap items-center gap-x-1.5 gap-y-1">
          <span aria-hidden>·</span>
          <span>
            <span className="tabular font-medium text-ink">{formatTotal(data.net_aed)}</span> net
          </span>
          {data.has_estimate && (
            <Tooltip content="Some AED amounts use an estimated exchange rate and may move when statements arrive.">
              <Badge tone="warn">AED estimated</Badge>
            </Tooltip>
          )}
          {data.unpriced_count > 0 && <span className="text-[12px] text-subtle">excl. {formatCount(data.unpriced_count)} without AED amount</span>}
        </span>
      )}
      {span && (
        <span className="tabular whitespace-nowrap">
          <span aria-hidden>·</span> {span}
        </span>
      )}
    </p>
  );
}
