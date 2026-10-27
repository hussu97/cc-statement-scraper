import { lazy, Suspense, useMemo, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { BriefcaseBusiness, Plus } from "lucide-react";
import {
  estimateNote,
  formatPositionPrice,
  formatQuantity,
  heldSpan,
  portfolioPoints,
  positionKind,
  positionRef,
  providerLabel,
  sellFromPosition,
  syncStatus,
  type BrokerPortfolio,
  type BrokerPosition,
  type ClosedPosition,
} from "@/lib/broker";
import { calledNext, isEnded, noteStatus, pct, returnText } from "@/lib/notes";
import { signTone } from "@/lib/holdings";
import { formatDate } from "@/lib/dates";
import { formatMoney, formatTotal, toAmount } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, LoadingBlock } from "@/components/ui/states";

// The chart library loads after the page renders (as on Overview, WEB-53).
const PortfolioChart = lazy(() => import("./portfolio-chart").then((m) => ({ default: m.PortfolioChart })));

const TONE = { positive: "text-positive", danger: "text-danger", neutral: "text-ink-2" } as const;
const signed = (v: string | null | undefined, currency: string) => formatMoney(v, { currency, signed: true });
const signedTotal = (v: string | null | undefined, currency: string) => formatTotal(v, { currency, signed: true });

function Stat({ label, children, sub, tone }: { label: string; children: ReactNode; sub?: ReactNode; tone?: keyof typeof TONE }) {
  return (
    <div className="min-w-0">
      <dt className="text-[12px] text-subtle">{label}</dt>
      <dd className={cn("tabular mt-0.5 text-[15px] font-medium text-ink", tone && TONE[tone])}>{children}</dd>
      {sub && <dd className="text-[11px] text-muted">{sub}</dd>}
    </div>
  );
}

/** The portfolio at the broker: what it is worth, what went in, what it made, and its value over time. */
export function PortfolioCard({ portfolio: p }: { portfolio: BrokerPortfolio }) {
  const c = p.currency;
  const sync = syncStatus(p.sync);
  const points = useMemo(() => portfolioPoints(p.series), [p.series]);
  const note = estimateNote(p.series);
  return (
    <Card>
      <div className="px-5 pt-5">
        <p className="text-[12px] text-subtle">Portfolio at {providerLabel(p.provider)}</p>
        <p className="tabular mt-0.5 text-[32px] leading-tight font-medium text-ink">{formatTotal(p.total, { currency: c })}</p>
        {c.toUpperCase() !== "AED" && <p className="tabular text-[12px] text-subtle">{p.total_aed ? `≈ ${formatTotal(p.total_aed)}` : "No AED rate yet"}</p>}
        <p className={cn("mt-1 text-[12px]", sync.tone === "danger" ? "text-danger" : "text-subtle")}>
          {sync.text}
          {p.as_of && sync.tone !== "danger" ? ` · values as of ${formatDate(p.as_of)}` : ""}
        </p>
      </div>
      <dl className="grid grid-cols-2 gap-x-6 gap-y-3 px-5 pt-4 sm:grid-cols-3 xl:grid-cols-6">
        <Stat label="Cash">{formatTotal(p.cash, { currency: c })}</Stat>
        <Stat label="In positions">{formatTotal(p.positions_value, { currency: c })}</Stat>
        <Stat label="Net deposits" sub="Paid in less taken out">
          {formatTotal(p.net_deposits, { currency: c })}
        </Stat>
        <Stat label="Profit" tone={signTone(p.profit)} sub="Value less net deposits">
          {signedTotal(p.profit, c)}
        </Stat>
        <Stat label="Income received" sub="Coupons and dividends">
          {formatTotal(p.income, { currency: c })}
        </Stat>
        <Stat label="Fees">{formatTotal(p.fees, { currency: c })}</Stat>
      </dl>
      <div className="px-3 pt-4 pb-4 md:px-4">
        <div className="mb-1 flex flex-wrap items-center justify-between gap-2 px-2">
          <p className="text-[11px] font-medium tracking-[0.06em] text-subtle uppercase">Value against net deposits</p>
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
        <span aria-hidden className="inline-block h-0.5 w-3 rounded-pill bg-[var(--chart-axis)]" /> Net deposits
      </li>
    </ul>
  );
}

/** Every open position at the broker: notes, bonds and shares, with what each fetches sold today and, for a note, if called. */
export function PositionsCard({ portfolio: p, onAdd }: { portfolio: BrokerPortfolio; onAdd?: () => void }) {
  const c = p.currency;
  const anyCall = p.positions.some((x) => calledNext(x.note?.if_called_next));
  return (
    <Card>
      <CardHeader
        eyebrow={`${p.positions.length} open`}
        title="Positions"
        action={
          onAdd && (
            <Button size="sm" icon={<Plus className="size-3.5" />} onClick={onAdd}>
              <span className="sm:hidden">Add note</span>
              <span className="hidden sm:inline">Add a note from its term sheet</span>
            </Button>
          )
        }
      />
      {p.positions.length === 0 ? (
        <EmptyState icon={<BriefcaseBusiness />} title="No open positions">
          The last sync found only cash in this portfolio.
        </EmptyState>
      ) : (
        <div className="overflow-x-auto px-5 pb-4">
          <table className="w-full min-w-[860px] text-[13px]">
            <thead className="text-left text-[11px] text-subtle uppercase">
              <tr className="border-b border-border">
                <th className="py-2 pr-3 font-medium">Position</th>
                <th className="py-2 pr-3 text-right font-medium">Quantity</th>
                <th className="py-2 pr-3 text-right font-medium">Price</th>
                <th className="py-2 pr-3 text-right font-medium">Value</th>
                <th className="py-2 pr-3 text-right font-medium">Sell today</th>
                {anyCall && <th className="py-2 text-right font-medium">If called</th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {p.positions.map((x) => (
                <PositionRow key={x.holding_code} x={x} currency={x.currency || c} showCall={anyCall} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}

function PositionRow({ x, currency, showCall }: { x: BrokerPosition; currency: string; showCall: boolean }) {
  const sell = sellFromPosition(x);
  const called = calledNext(x.note?.if_called_next);
  const isNote = positionKind(x.kind) === "structured_note";
  const status = x.note ? noteStatus(x.note.status) : null;
  const income = toAmount(x.income);
  return (
    <tr className="align-top">
      <td className="min-w-56 py-2.5 pr-3">
        <div className="flex flex-wrap items-center gap-2">
          <Link to="/wealth/investments/$holdingCode" params={{ holdingCode: x.holding_code }} className="font-medium text-ink hover:text-accent hover:underline">
            {x.name}
          </Link>
          {isNote && <Badge tone={status && x.note?.status !== "live" ? status.tone : "accent"}>{status && x.note?.status !== "live" ? status.label : "Note"}</Badge>}
          {x.note?.awaiting_prices && <Badge tone="warn">Awaiting prices</Badge>}
        </div>
        <p className="mt-0.5 text-[12px] text-muted">
          {positionRef(x)}
          {x.note && !isEnded(x.note.status) && x.note.worst_now && (
            <>
              {" · "}worst {x.note.worst_now.symbol} at {pct(x.note.worst_now.pct, 2)}
            </>
          )}
          {x.note?.next && !isEnded(x.note.status) && <> · next {formatDate(x.note.next.obs_date, "short")}</>}
        </p>
      </td>
      <td className="tabular py-2.5 pr-3 text-right whitespace-nowrap">
        {formatQuantity(x.quantity)}
        {x.price_in_pct && <span className="block text-[11px] text-muted">nominal</span>}
      </td>
      <td className="tabular py-2.5 pr-3 text-right whitespace-nowrap">{formatPositionPrice(x)}</td>
      <td className="tabular py-2.5 pr-3 text-right whitespace-nowrap">
        <span className="font-medium text-ink">{formatMoney(x.value, { currency })}</span>
        {x.invested && <span className="block text-[11px] text-muted">paid {formatMoney(x.invested, { currency })}</span>}
      </td>
      <td className="tabular py-2.5 pr-3 text-right whitespace-nowrap">
        {sell ? (
          <>
            <span className={cn("font-medium", TONE[signTone(sell.profit)])}>{signed(sell.profit, currency)}</span>
            {sell.returnPct && <span className="block text-[11px] text-muted">{pct(sell.returnPct, 2)}</span>}
            {income !== null && income > 0 && <span className="block text-[11px] text-muted">with {formatMoney(x.income, { currency })} income</span>}
          </>
        ) : (
          <span className="text-muted">—</span>
        )}
      </td>
      {showCall && (
        <td className="tabular py-2.5 text-right whitespace-nowrap">
          {called ? (
            <>
              <span className="font-medium text-ink">{formatMoney(called.total, { currency })}</span>{" "}
              <span className={cn("font-medium", TONE[signTone(called.profit)])}>{signed(called.profit, currency)}</span>
              <span className="block text-[11px] text-muted">
                on {formatDate(called.payDate, "short")}
                {called.annualisedPct ? ` · ${pct(called.annualisedPct, 2)} a year` : ""}
              </span>
            </>
          ) : isNote ? (
            <span className="text-[12px] text-muted">runs to maturity</span>
          ) : (
            <span className="text-muted">—</span>
          )}
        </td>
      )}
    </tr>
  );
}

/** Positions sold, called or matured: what went in, what came back, and the return. */
export function ClosedPositionsCard({ closed, currency }: { closed: ClosedPosition[]; currency: string }) {
  if (closed.length === 0) return null;
  return (
    <Card>
      <CardHeader eyebrow={`${closed.length} closed`} title="Past positions" />
      <ul className="divide-y divide-border border-t border-border">
        {closed.map((x) => (
          <li key={x.holding_code}>
            <ClosedRow x={x} currency={currency} />
          </li>
        ))}
      </ul>
    </Card>
  );
}

function ClosedRow({ x, currency }: { x: ClosedPosition; currency: string }) {
  const status = x.note_status ? noteStatus(x.note_status) : null;
  const income = toAmount(x.income);
  return (
    <Link
      to="/wealth/investments/$holdingCode"
      params={{ holdingCode: x.holding_code }}
      className="tap flex flex-wrap items-start gap-x-4 gap-y-1 px-5 py-3 hover:bg-surface-2/60 focus-visible:bg-surface-2/60"
    >
      <div className="min-w-0 flex-1 basis-64">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm font-medium text-ink">{x.name}</span>
          {status && <Badge tone={status.tone}>{status.label}</Badge>}
        </div>
        <p className="mt-0.5 text-[12px] text-muted">
          {heldSpan(x)}
          {x.isin ? ` · ${x.isin}` : ""}
        </p>
      </div>
      <div className="tabular text-[12px] text-muted sm:text-right">
        <p>
          {formatMoney(x.invested, { currency })} → <span className="text-ink-2">{formatMoney(x.returned, { currency })}</span>
        </p>
        {income !== null && income > 0 && <p>+ {formatMoney(x.income, { currency })} income</p>}
      </div>
      <div className="tabular min-w-36 text-right">
        <p className={cn("text-sm font-medium", TONE[signTone(x.profit)])}>{signed(x.profit, currency)}</p>
        <p className="text-[12px] text-muted">{returnText(x.return_pct, x.annualised_pct)}</p>
      </div>
    </Link>
  );
}
