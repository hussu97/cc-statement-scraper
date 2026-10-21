import { useMemo, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowLeftRight, ChevronLeft, ChevronRight } from "lucide-react";
import { useCashFlow } from "@/data/cash";
import { useCashFlowSavings } from "@/data/holdings";
import { savingLines, type SavingLine } from "@/lib/investments";
import { cashFlowRange, formatFlow, formatNet, monthFlows, netByMonth, netTone, type FlowGroup, type FlowLine } from "@/lib/cash-flow";
import { addMonths, formatMonth, monthEnd } from "@/lib/dates";
import { formatCount } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState } from "@/components/ui/states";

const TONE_TEXT = { positive: "text-positive", danger: "text-danger", neutral: "text-ink" } as const;

/** What a partial month (cash_flow.is_partial) means, in one sentence. */
const PARTIAL_NOTE = "Before your first bank alert or balance: card spending is here but money in wasn't captured, so this net isn't a loss.";

/**
 * One month's money in and out by group, and the net of the last six months (public.cash_flow).
 * `account` narrows it to one bank account. The Unfiled lines open `unfiledAccount`'s ledger for
 * the month (one account), else the accounts list.
 */
export function CashFlowCard({
  profileCode,
  month,
  thisMonth,
  onMonth,
  account,
  unfiledAccount,
  headerExtra,
}: {
  profileCode: string;
  month: string;
  thisMonth: string;
  onMonth: (m: string) => void;
  account?: string;
  unfiledAccount?: string;
  headerExtra?: ReactNode;
}) {
  const range = cashFlowRange(month);
  const q = useCashFlow(profileCode, range, account);
  const flows = useMemo(() => monthFlows(q.data ?? [], month), [q.data, month]);
  const nets = useMemo(() => netByMonth(q.data ?? [], month), [q.data, month]);
  const isCurrent = month === thisMonth;
  const savingsQ = useCashFlowSavings(profileCode, { from: month, to: monthEnd(month) }, account);
  const savings = useMemo(() => savingLines(savingsQ.data ?? [], month), [savingsQ.data, month]);

  return (
    <Card>
      <CardHeader
        eyebrow="Cash flow"
        title={`${formatMonth(month)}${isCurrent ? " so far" : ""}`}
        action={
          <div className="flex items-center gap-1">
            {headerExtra}
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
            {flows.partial && flows.hasMovements && (
              <p className="mb-4 flex flex-wrap items-baseline gap-x-2 gap-y-1 rounded-md bg-surface-2 px-3 py-2 text-[12px] text-muted">
                <Badge tone="info">Partial month</Badge>
                <span>{PARTIAL_NOTE}</span>
              </p>
            )}
            {flows.hasMovements ? (
              <>
                <div className="flex flex-col gap-4">
                  {flows.groups.map((g) => (
                    <GroupBlock key={g.key} group={g} month={month} unfiledAccount={unfiledAccount} savings={savings} />
                  ))}
                </div>
                <div className="mt-4 flex items-baseline justify-between gap-3 border-t border-border pt-3">
                  <span className="text-sm font-semibold text-ink">Net{flows.partial && <span className="ml-2 text-[11px] font-normal text-subtle">partial month</span>}</span>
                  <span className={cn("tabular text-lg font-medium", flows.partial ? "text-muted" : TONE_TEXT[netTone(flows.net)])}>{formatNet(flows.net)}</span>
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
                    <td className={cn("tabular py-2 pr-2 text-right", r.net === null ? "text-subtle" : r.partial ? "text-muted" : TONE_TEXT[netTone(r.net)])}>
                      {r.partial && r.net !== null && <span className="mr-2 text-[11px] text-subtle">partial</span>}
                      {formatNet(r.net)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p className="mt-2 text-[11px] text-subtle">Money in less spending, commitments and unfiled money out. Card repayments and moves between your own accounts don't count.</p>
            {nets.some((r) => r.partial && r.net !== null) && <p className="mt-1 text-[11px] text-subtle">Partial: before your first bank alert or balance, so money in is missing.</p>}
          </div>
        </div>
      )}
    </Card>
  );
}

function GroupBlock({ group: g, month, unfiledAccount, savings }: { group: FlowGroup; month: string; unfiledAccount?: string; savings: SavingLine[] }) {
  return (
    <section aria-label={g.label} className={cn(g.muted && "text-muted")}>
      <div className="mb-1 flex items-baseline justify-between gap-2">
        <h3 className={cn("text-[12px] font-medium tracking-[0.06em] uppercase", g.muted ? "text-subtle" : "text-ink-2")}>{g.label}</h3>
        {g.note && <span className="text-[11px] text-subtle">{g.note}</span>}
      </div>
      <ul className="flex flex-col">
        {g.lines.map((l) => (
          <LineRow key={l.flow} line={l} muted={g.muted} month={month} unfiledAccount={unfiledAccount} breakdown={l.flow === "saving" ? savings : undefined} />
        ))}
      </ul>
    </section>
  );
}

function LineRow({ line: l, muted, month, unfiledAccount, breakdown }: { line: FlowLine; muted: boolean; month: string; unfiledAccount?: string; breakdown?: SavingLine[] }) {
  const amount = formatFlow(l.amount, l.direction);
  const count = `${formatCount(l.count)} ${l.count === 1 ? "transaction" : "transactions"}`;
  return (
    <li className="py-1">
      <div className="flex items-baseline justify-between gap-3">
        <span className="min-w-0 truncate text-sm">
          {l.unfiled ? (
            unfiledAccount ? (
              <Link
                to="/wealth/accounts/$accountCode"
                params={{ accountCode: unfiledAccount }}
                search={{ month: month.slice(0, 7) }}
                className="text-accent hover:underline"
                title="File them from the account's ledger"
              >
                {l.label}
              </Link>
            ) : (
              <Link to="/wealth/accounts" className="text-accent hover:underline" title="File them from each account's ledger">
                {l.label}
              </Link>
            )
          ) : (
            <span className={muted ? "text-muted" : "text-ink"}>{l.label}</span>
          )}
          <span className="ml-2 text-[11px] text-subtle">{count}</span>
        </span>
        <span className={cn("tabular shrink-0 text-sm", muted ? "text-muted" : l.direction === "in" ? "text-positive" : "text-ink")}>{amount}</span>
      </div>
      {breakdown && breakdown.length > 0 && <SavingBreakdown lines={breakdown} />}
    </li>
  );
}

/** Saving by holding (cash_flow_savings): each holding's linked payments, and "Unassigned" for saving filed by category only. */
function SavingBreakdown({ lines }: { lines: SavingLine[] }) {
  return (
    <ul aria-label="Saving by investment" className="mt-1 ml-1 flex flex-col border-l border-border pl-3">
      {lines.map((s) => (
        <li key={s.key} className="flex items-baseline justify-between gap-3 py-0.5 text-[13px]">
          <span className="min-w-0 truncate">
            {s.holdingCode ? (
              <Link to="/wealth/investments/$holdingCode" params={{ holdingCode: s.holdingCode }} className="text-ink-2 hover:text-accent hover:underline">
                {s.label}
              </Link>
            ) : (
              <span className="text-muted" title="Filed under a saving category, not linked to an investment">
                {s.label}
              </span>
            )}
            <span className="ml-2 text-[11px] text-subtle">
              {formatCount(s.count)} {s.count === 1 ? "transaction" : "transactions"}
            </span>
          </span>
          <span className="tabular shrink-0 text-ink-2">{formatFlow(s.amount, "out")}</span>
        </li>
      ))}
    </ul>
  );
}
