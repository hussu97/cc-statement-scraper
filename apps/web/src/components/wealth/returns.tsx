import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { TrendingUp } from "lucide-react";
import { useHoldingReturns, type HoldingReturnRow } from "@/data/holdings";
import { formatPct, signTone } from "@/lib/holdings";
import { RETURN_PERIODS, incompleteDetail, incompleteNote, incompleteReason, returnsParts, type ReturnFigures, type ReturnPeriod } from "@/lib/investments";
import { formatDate } from "@/lib/dates";
import { formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { Segmented } from "@/components/ui/segmented";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { TONE_TEXT } from "./investments";

/**
 * Returns for all time, this year or the last 12 months (holding_returns): what was added, what it
 * grew by and the money-weighted yearly return, in total and per holding. With `holdingCode`, one
 * holding's figures only. Every figure is the server's.
 */
export function ReturnsCard({ profileCode, holdingCode }: { profileCode: string; holdingCode?: string }) {
  const [period, setPeriod] = useState<ReturnPeriod>("all");
  const q = useHoldingReturns(profileCode, period);
  const one = holdingCode ? q.data?.holdings.find((h) => h.holding_code === holdingCode) : undefined;
  const switcher = <Segmented ariaLabel="Period" value={period} onChange={setPeriod} options={[...RETURN_PERIODS]} />;
  return (
    <Card>
      <CardHeader eyebrow="Returns" title={holdingCode ? "How it has done" : "New money and growth"} action={<div className="hidden sm:block">{switcher}</div>} />
      <div className="px-5 pb-3 sm:hidden">{switcher}</div>
      {q.isLoading ? (
        <LoadingRows rows={3} />
      ) : q.isError || !q.data ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : holdingCode ? (
        one ? (
          <div className={cn("px-5 pb-5", q.isPlaceholderData && "opacity-60")}>
            <Figures r={one} />
            {!one.complete && (
              <p className="mt-3 text-[12px] text-warn">{incompleteDetail(one, period)}</p>
            )}
          </div>
        ) : (
          <EmptyState icon={<TrendingUp />} title="No returns for this holding">
            A closed holding has no returns.
          </EmptyState>
        )
      ) : q.data.holdings.length === 0 ? (
        <EmptyState icon={<TrendingUp />} title="No investments yet">
          Add a holding: its returns show here, split into the money you put in and how it grew.
        </EmptyState>
      ) : (
        <div className={cn(q.isPlaceholderData && "opacity-60")}>
          <div className="px-5 pb-4">
            <Figures r={q.data.total} />
            {q.data.from && <p className="mt-1 text-[11px] text-subtle">From {formatDate(q.data.from)} to today.</p>}
            {incompleteNote(q.data.holdings, period) && <p className="mt-2 text-[12px] text-warn">{incompleteNote(q.data.holdings, period)}</p>}
          </div>
          <ReturnsTable rows={q.data.holdings} period={period} />
          <p className="px-5 py-3 text-[11px] text-subtle">
            Added is money put in less money taken out. Growth is the change in value beyond that, plus income paid out. The yearly return weighs each amount by how long it was
            invested, and shows from 90 days of history.
          </p>
        </div>
      )}
    </Card>
  );
}

/** "Added AED X · Grew AED Y (Z%) · N% a year" for a total or one holding. */
function Figures({ r }: { r: ReturnFigures }) {
  const p = returnsParts(r);
  return (
    <p className="flex flex-wrap items-baseline gap-x-2 gap-y-1 text-[15px]">
      <span className="tabular text-ink">{p.added}</span>
      <span aria-hidden className="text-subtle">·</span>
      {p.grew === null ? <span className="text-muted">Growth not known</span> : <span className={cn("tabular", TONE_TEXT[signTone(r.growth_aed)])}>{p.grew}</span>}
      <span aria-hidden className="text-subtle">·</span>
      <span className={cn("tabular", r.annual_pct === null ? "text-[13px] text-muted" : TONE_TEXT[signTone(r.annual_pct)])}>{p.annual}</span>
    </p>
  );
}

function ReturnsTable({ rows, period }: { rows: HoldingReturnRow[]; period: ReturnPeriod }) {
  return (
    <div className="overflow-x-auto border-t border-border">
      <table className="w-full min-w-[34rem] text-sm">
        <caption className="sr-only">Returns by holding</caption>
        <thead>
          <tr className="border-b border-border text-[11px] font-medium tracking-wide text-subtle uppercase">
            <th scope="col" className="px-5 py-2 text-left font-medium">
              Holding
            </th>
            <th scope="col" className="px-3 py-2 text-right font-medium">
              Added
            </th>
            <th scope="col" className="px-3 py-2 text-right font-medium">
              Growth
            </th>
            <th scope="col" className="px-3 py-2 text-right font-medium">
              Simple
            </th>
            <th scope="col" className="px-5 py-2 text-right font-medium">
              A year
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-border">
          {rows.map((r) => (
            <tr key={r.holding_code}>
              <th scope="row" className="px-5 py-2 text-left font-normal">
                <Link to="/wealth/investments/$holdingCode" params={{ holdingCode: r.holding_code }} className="text-ink hover:text-accent hover:underline">
                  {r.name}
                </Link>
              </th>
              <td className="tabular px-3 py-2 text-right text-ink-2">{formatTotal(r.added_aed)}</td>
              {r.complete ? (
                <>
                  <td className={cn("tabular px-3 py-2 text-right", TONE_TEXT[signTone(r.growth_aed)])}>{formatTotal(r.growth_aed, { signed: true })}</td>
                  <td className={cn("tabular px-3 py-2 text-right", TONE_TEXT[signTone(r.simple_pct)])}>{formatPct(r.simple_pct, { signed: true }) ?? "—"}</td>
                  <td className={cn("tabular px-5 py-2 text-right", r.annual_pct === null ? "text-subtle" : TONE_TEXT[signTone(r.annual_pct)])}>
                    {formatPct(r.annual_pct, { signed: true }) ?? "—"}
                  </td>
                </>
              ) : (
                <td colSpan={3} className="px-5 py-2 text-right text-[12px] text-subtle">
                  {incompleteReason(r, period)}
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
