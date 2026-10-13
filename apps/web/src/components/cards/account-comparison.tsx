import { useMemo } from "react";
import { useAccounts } from "@/data/cards";
import { useSpendSeries } from "@/data/analytics";
import { accountLabel } from "@/data/overview";
import {
  COMPARISON_MONTHS,
  COMPARISON_STATEMENTS,
  comparisonRange,
  monthlySpendByAccount,
  monthsBetween,
  sparkValues,
  statementTrends,
  useCycleHistory,
  type MonthPoint,
  type StatementPoint,
} from "@/data/account-trends";
import { formatDate, formatMonth, todayDubai } from "@/lib/dates";
import { formatPercent, formatTotal, type MoneyInput } from "@/lib/money";
import { Card, CardHeader, Skeleton } from "@/components/ui/display";
import { ErrorState } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { Sparkline } from "@/components/charts/sparkline";
import { categoryVar, rankToken } from "@/components/charts/palette";

/**
 * Cards → compare accounts (MA-2): per card account, its statement balance and utilisation over
 * its last 12 statements and its spending over the last 12 months, as small sparklines with the
 * latest server value beside each. Hand-rolled SVG, so Cards doesn't load the chart library.
 */
export function AccountComparison({ profileCode }: { profileCode: string }) {
  const accounts = useAccounts(profileCode);
  const cycles = useCycleHistory(profileCode);
  const range = useMemo(() => comparisonRange(todayDubai()), []);
  const spend = useSpendSeries(profileCode, range, "month", "account");
  const months = useMemo(() => monthsBetween(range.from, range.to), [range]);
  const statements = useMemo(() => (cycles.data ? statementTrends(cycles.data) : null), [cycles.data]);
  const spending = useMemo(() => (spend.data ? monthlySpendByAccount(spend.data, months) : null), [spend.data, months]);

  // The account cards above already say when there are none, or that they failed.
  if (accounts.isError || (accounts.data && accounts.data.length === 0)) return null;

  return (
    <Card className="mt-6">
      <CardHeader eyebrow="Compare" title="Balances, utilisation and spending" />
      {accounts.isLoading ? (
        <div role="status" aria-label="Loading" className="flex flex-col gap-3 px-5 pb-5">
          <Skeleton className="h-16 w-full" />
          <Skeleton className="h-16 w-full" />
        </div>
      ) : (
        <ul className="divide-y divide-border border-t border-border">
          {(accounts.data ?? []).map((a, i) => (
            <li key={a.account_code} className="grid gap-4 px-5 py-4 md:grid-cols-[minmax(9rem,1fr)_repeat(3,minmax(0,1fr))] md:items-center md:gap-6">
              <div className="flex min-w-0 items-center gap-3">
                <BankLogo bankCode={a.bank_code} size="sm" decorative />
                <div className="min-w-0">
                  <p className="truncate text-[13.5px] font-medium text-ink">{accountLabel(a)}</p>
                  {a.status !== "active" && <p className="text-[12px] text-subtle">{a.status}</p>}
                </div>
              </div>
              <div className="grid grid-cols-3 gap-3 md:contents">
                <StatementCells
                  query={cycles}
                  points={statements?.get(a.account_code) ?? []}
                  color={categoryVar(rankToken(i))}
                />
                <SpendCell query={spend} points={spending?.get(a.account_code) ?? null} months={months} color={categoryVar(rankToken(i))} />
              </div>
            </li>
          ))}
        </ul>
      )}
      <p className="border-t border-border px-5 py-3 text-[12px] text-subtle">
        Balance and utilisation are from each account's last {COMPARISON_STATEMENTS} statements; spending covers the last {COMPARISON_MONTHS} months.
      </p>
    </Card>
  );
}

/** "Statement balance" doesn't fit a phone's third of a row. */
const BALANCE_LABEL = (
  <>
    <span className="md:hidden">Balance</span>
    <span className="hidden md:inline">Statement balance</span>
  </>
);

interface QueryState {
  isLoading: boolean;
  isError: boolean;
  error: unknown;
  refetch: () => unknown;
}

function StatementCells({ query, points, color }: { query: QueryState; points: StatementPoint[]; color: string }) {
  if (query.isLoading) return <><CellSkeleton /><CellSkeleton /></>;
  if (query.isError) {
    return (
      <div className="col-span-2">
        <ErrorState title="Couldn't load statements" error={query.error} onRetry={() => void query.refetch()} className="py-3" />
      </div>
    );
  }
  if (points.length === 0) {
    return (
      <>
        <Cell label={BALANCE_LABEL} value="—" caption="No statements yet" />
        <Cell label="Utilisation" value="—" caption="No statements yet" />
      </>
    );
  }
  const first = points[0]!;
  const latest = points.at(-1)!;
  const span = points.length === 1 ? `${formatDate(latest.statement_date, "short")} statement` : `${points.length} statements`;
  const between = (pick: (p: StatementPoint) => string) =>
    points.length === 1 ? `${pick(latest)} on ${formatDate(latest.statement_date)}` : `${pick(first)} on ${formatDate(first.statement_date)} to ${pick(latest)} on ${formatDate(latest.statement_date)}`;
  const balance = (p: StatementPoint) => formatTotal(p.closing_balance);
  const util = (p: StatementPoint) => formatPercent(p.utilisation);
  const hasUtil = points.some((p) => p.utilisation !== null && p.utilisation !== undefined);
  return (
    <>
      <Cell
        label={BALANCE_LABEL}
        value={formatTotal(latest.closing_balance)}
        caption={span}
        spark={<Sparkline values={sparkValues(points.map((p) => p.closing_balance))} color={color} label={`Statement balance, ${between(balance)}`} />}
      />
      <Cell
        label="Utilisation"
        value={hasUtil ? formatPercent(latest.utilisation) : "—"}
        caption={hasUtil ? limitCaption(latest.credit_limit) : "No credit limit known"}
        spark={
          hasUtil ? (
            <Sparkline values={sparkValues(points.map((p) => p.utilisation))} color={color} min={0} max={1} label={`Utilisation of the credit limit, ${between(util)}`} />
          ) : undefined
        }
      />
    </>
  );
}

function limitCaption(limit: MoneyInput): string {
  return limit === null || limit === undefined ? "of the limit" : `of ${formatTotal(limit)}`;
}

function SpendCell({ query, points, months, color }: { query: QueryState; points: MonthPoint[] | null; months: string[]; color: string }) {
  if (query.isLoading) return <CellSkeleton />;
  if (query.isError) return <ErrorState title="Couldn't load spending" error={query.error} onRetry={() => void query.refetch()} className="py-3" />;
  // No row for this account in any month: the server found no spending on it.
  if (!points) return <Cell label="Spending" value={formatTotal(0)} caption={`None in ${COMPARISON_MONTHS} months`} />;
  const latest = points.at(-1)!;
  const first = points[0]!;
  return (
    <Cell
      label="Spending"
      value={formatTotal(latest.amount)}
      caption={`${formatMonth(latest.month, "short")} so far`}
      spark={
        <Sparkline
          values={sparkValues(points.map((p) => p.amount))}
          color={color}
          min={0}
          label={`Monthly spending, ${formatTotal(first.amount)} in ${formatMonth(first.month)} to ${formatTotal(latest.amount)} in ${formatMonth(latest.month)} so far, over ${months.length} months`}
        />
      }
    />
  );
}

function Cell({ label, value, caption, spark }: { label: React.ReactNode; value: string; caption: string; spark?: React.ReactNode }) {
  return (
    <div className="min-w-0">
      <p className="truncate text-[11.5px] text-subtle">{label}</p>
      <p className="tabular mt-0.5 truncate text-[14px] text-ink">{value}</p>
      <div className="mt-1.5">{spark ?? <div className="h-8 border-b border-dashed border-border" aria-hidden />}</div>
      <p className="mt-1 truncate text-[11px] text-subtle">{caption}</p>
    </div>
  );
}

function CellSkeleton() {
  return (
    <div className="flex min-w-0 flex-col gap-1.5" aria-hidden>
      <Skeleton className="h-2.5 w-2/3" />
      <Skeleton className="h-3.5 w-1/2" />
      <Skeleton className="h-8 w-full" />
    </div>
  );
}
