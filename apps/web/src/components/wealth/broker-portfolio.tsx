import { lazy, Suspense, useMemo, type ReactNode } from "react";
import { estimateNote, portfolioPoints, syncStatus, type BrokerPortfolio } from "@/lib/broker";
import { signTone } from "@/lib/holdings";
import { formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card } from "@/components/ui/display";
import { EmptyState, LoadingBlock } from "@/components/ui/states";

// The chart library loads after the page renders (as on Overview, WEB-53).
const PortfolioChart = lazy(() => import("./portfolio-chart").then((m) => ({ default: m.PortfolioChart })));

export const TONE_TEXT = { positive: "text-positive", danger: "text-danger", neutral: "text-ink" } as const;

function Figure({ label, children, sub }: { label: string; children: ReactNode; sub?: ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-[12px] text-subtle">{label}</dt>
      <dd className="tabular mt-0.5 text-[19px] leading-tight font-medium whitespace-nowrap text-ink sm:text-[26px]">{children}</dd>
      {sub && <dd className="tabular mt-0.5 text-[12px] text-muted">{sub}</dd>}
    </div>
  );
}

/** The account at the broker in three numbers (value, profit, cash), when it last synced, and its value against what went in. */
export function PortfolioCard({ portfolio: p }: { portfolio: BrokerPortfolio }) {
  const c = p.currency;
  const sync = syncStatus(p.sync);
  const points = useMemo(() => portfolioPoints(p.series), [p.series]);
  const note = estimateNote(p.series);
  return (
    <Card>
      <dl className="grid grid-cols-2 gap-x-4 gap-y-4 px-5 pt-5 sm:grid-cols-3 sm:gap-x-6">
        <Figure label="Total value" sub={c.toUpperCase() !== "AED" ? (p.total_aed ? `≈ ${formatTotal(p.total_aed)}` : "No AED rate yet") : undefined}>
          {formatTotal(p.total, { currency: c })}
        </Figure>
        <Figure label="Profit" sub={p.net_deposits ? `on ${formatTotal(p.net_deposits, { currency: c })} put in` : undefined}>
          <span className={TONE_TEXT[signTone(p.profit)]}>{formatTotal(p.profit, { currency: c, signed: true })}</span>
        </Figure>
        <Figure label="Cash">{formatTotal(p.cash, { currency: c })}</Figure>
      </dl>
      <p className={cn("px-5 pt-2 text-[12px]", sync.tone === "danger" ? "text-warn" : "text-subtle")}>{sync.text}</p>
      <div className="px-3 pt-3 pb-4 md:px-4">
        <div className="mb-1 flex flex-wrap items-center justify-end gap-2 px-2">
          <Legend />
        </div>
        {points.length < 2 ? (
          <EmptyState title="No history yet" className="h-44">
            The line starts after the second day the portfolio is synced.
          </EmptyState>
        ) : (
          <Suspense fallback={<LoadingBlock className="h-56" />}>
            <PortfolioChart points={points} currency={c} />
          </Suspense>
        )}
        {note && points.length >= 2 && <p className="px-2 pt-1 text-[11px] text-muted">{note}</p>}
      </div>
    </Card>
  );
}

function Legend() {
  return (
    <ul className="flex items-center gap-3 text-[11px] text-muted">
      <li className="flex items-center gap-1.5">
        <span aria-hidden className="inline-block h-0.5 w-3 rounded-pill bg-accent" /> Value
      </li>
      <li className="flex items-center gap-1.5">
        <span aria-hidden className="inline-block h-0.5 w-3 rounded-pill bg-[var(--chart-axis)]" /> Put in
      </li>
    </ul>
  );
}
