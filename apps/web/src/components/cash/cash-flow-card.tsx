import { useMemo } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowLeftRight, ChevronLeft, ChevronRight } from "lucide-react";
import { useCashFlow } from "@/data/cash";
import { cashFlowRange, formatFlow, formatNet, monthFlows, netByMonth, netTone, type FlowGroup, type FlowLine } from "@/lib/cash-flow";
import { UNCATEGORIZED } from "@/lib/activity-filters";
import { addMonths, formatMonth, monthEnd } from "@/lib/dates";
import { formatCount } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card, CardHeader, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState } from "@/components/ui/states";

const TONE_TEXT = { positive: "text-positive", danger: "text-danger", neutral: "text-ink" } as const;

/**
 * One month's money in and out by group, and the net of the last six months (public.cash_flow).
 * `unfiledAccount` narrows the Unfiled links to the ledger's one bank account, when it has one.
 */
export function CashFlowCard({
  profileCode,
  month,
  thisMonth,
  onMonth,
  unfiledAccount,
}: {
  profileCode: string;
  month: string;
  thisMonth: string;
  onMonth: (m: string) => void;
  unfiledAccount?: string;
}) {
  const range = cashFlowRange(month);
  const q = useCashFlow(profileCode, range);
  const flows = useMemo(() => monthFlows(q.data ?? [], month), [q.data, month]);
  const nets = useMemo(() => netByMonth(q.data ?? [], month), [q.data, month]);
  const isCurrent = month === thisMonth;

  return (
    <Card>
      <CardHeader
        eyebrow="Cash flow"
        title={`${formatMonth(month)}${isCurrent ? " so far" : ""}`}
        action={
          <div className="flex items-center gap-1">
            <Button size="icon-sm" variant="ghost" aria-label="Previous month" onClick={() => onMonth(addMonths(month, -1))}>
              <ChevronLeft className="size-4" />
            </Button>
            <Button size="icon-sm" variant="ghost" aria-label="Next month" disabled={isCurrent} onClick={() => onMonth(addMonths(month, 1))}>
              <ChevronRight className="size-4" />
            </Button>
          </div>
        }
      />
      {q.isLoading ? (
        <div role="status" aria-label="Loading" className="flex flex-col gap-3 px-5 pb-5">
          <Skeleton className="h-5 w-1/2" />
          <Skeleton className="h-5 w-2/5" />
          <Skeleton className="h-5 w-3/5" />
          <Skeleton className="mt-3 h-24 w-full" />
        </div>
      ) : q.isError || !q.data ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : (
        <div className={cn("grid gap-6 px-5 pb-5 md:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]", q.isPlaceholderData && "opacity-60")}>
          <div>
            {flows.hasMovements ? (
              <>
                <div className="flex flex-col gap-4">
                  {flows.groups.map((g) => (
                    <GroupBlock key={g.key} group={g} month={month} unfiledAccount={unfiledAccount} />
                  ))}
                </div>
                <div className="mt-4 flex items-baseline justify-between gap-3 border-t border-border pt-3">
                  <span className="text-sm font-semibold text-ink">Net</span>
                  <span className={cn("tabular text-lg font-medium", TONE_TEXT[netTone(flows.net)])}>{formatNet(flows.net)}</span>
                </div>
              </>
            ) : (
              <EmptyState icon={<ArrowLeftRight />} title={`No money moved in ${formatMonth(month)}`}>
                Spending, transfers and income appear here as alerts and statements arrive.
              </EmptyState>
            )}
          </div>
          <div>
            <h3 className="mb-2 text-[12px] font-medium tracking-[0.06em] text-subtle uppercase">Net by month</h3>
            <table className="w-full text-sm">
              <caption className="sr-only">Net cash flow for the last six months</caption>
              <thead className="sr-only">
                <tr>
                  <th scope="col">Month</th>
                  <th scope="col">Net</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {nets.map((r) => (
                  <tr key={r.month} className={cn(r.month === month && "bg-surface-2/60")}>
                    <th scope="row" className="py-2 pl-2 text-left font-normal">
                      <button type="button" className="tap text-ink-2 hover:text-accent hover:underline" onClick={() => onMonth(r.month)} aria-current={r.month === month ? "date" : undefined}>
                        {r.label}
                      </button>
                    </th>
                    <td className={cn("tabular py-2 pr-2 text-right", r.net === null ? "text-subtle" : TONE_TEXT[netTone(r.net)])}>{formatNet(r.net)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p className="mt-2 text-[11px] text-subtle">Money in less spending, commitments and unfiled money out. Card repayments and moves between your own accounts don't count.</p>
          </div>
        </div>
      )}
    </Card>
  );
}

function GroupBlock({ group: g, month, unfiledAccount }: { group: FlowGroup; month: string; unfiledAccount?: string }) {
  return (
    <section aria-label={g.label} className={cn(g.muted && "text-muted")}>
      <div className="mb-1 flex items-baseline justify-between gap-2">
        <h3 className={cn("text-[12px] font-medium tracking-[0.06em] uppercase", g.muted ? "text-subtle" : "text-ink-2")}>{g.label}</h3>
        {g.note && <span className="text-[11px] text-subtle">{g.note}</span>}
      </div>
      <ul className="flex flex-col">
        {g.lines.map((l) => (
          <LineRow key={l.flow} line={l} muted={g.muted} month={month} unfiledAccount={unfiledAccount} />
        ))}
      </ul>
    </section>
  );
}

function LineRow({ line: l, muted, month, unfiledAccount }: { line: FlowLine; muted: boolean; month: string; unfiledAccount?: string }) {
  const amount = formatFlow(l.amount, l.direction);
  const count = `${formatCount(l.count)} ${l.count === 1 ? "transaction" : "transactions"}`;
  return (
    <li className="flex items-baseline justify-between gap-3 py-1">
      <span className="min-w-0 truncate text-sm">
        {l.unfiled ? (
          <Link
            to="/activity"
            search={{ category: UNCATEGORIZED, from: month, to: monthEnd(month), ...(unfiledAccount ? { account: unfiledAccount } : {}) }}
            className="text-accent hover:underline"
          >
            {l.label}
          </Link>
        ) : (
          <span className={muted ? "text-muted" : "text-ink"}>{l.label}</span>
        )}
        <span className="ml-2 text-[11px] text-subtle">{count}</span>
      </span>
      <span className={cn("tabular shrink-0 text-sm", muted ? "text-muted" : l.direction === "in" ? "text-positive" : "text-ink")}>{amount}</span>
    </li>
  );
}
