import { Link } from "@tanstack/react-router";
import { BriefcaseBusiness, ChevronRight } from "lucide-react";
import { groupBySegment, holdingResult, segmentHolds, segmentLabel, splitPositions, type BrokerPortfolio, type BrokerPosition } from "@/lib/broker";
import { formatUnits } from "@/lib/investments";
import { calledNext, pct } from "@/lib/notes";
import { verdictDate } from "@/lib/note-verdict";
import { signTone } from "@/lib/holdings";
import { formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { EmptyState } from "@/components/ui/states";
import { StockBars, VerdictText } from "@/components/notes/stock-bars";
import { TONE_TEXT } from "./broker-portfolio";

/**
 * The Portfolio tab: a card per live note (verdict, two numbers, its stocks), then everything else
 * in one line each. Against cost (Zerodha): a card per segment (Kite, Coin), each holding with its
 * units, what it cost, its worth and its P&L.
 */
export function PortfolioTab({ portfolio: p }: { portfolio: BrokerPortfolio }) {
  const { notes, others } = splitPositions(p.positions);
  if (p.positions.length === 0) {
    return (
      <Card>
        <EmptyState icon={<BriefcaseBusiness />} title="No open positions">
          The last sync found only cash in this portfolio.
        </EmptyState>
      </Card>
    );
  }
  if (p.basis === "cost") {
    return (
      <div className="flex flex-col gap-6">
        {groupBySegment(p.positions).map((g) => (
          <Card key={g.segment}>
            <CardHeader eyebrow={segmentLabel(g.segment)} title={`${segmentHolds(g.segment)} · ${g.items.length}`} />
            <ul className="divide-y divide-border border-t border-border">
              {g.items.map((x) => (
                <li key={x.holding_code}>
                  <HoldingRow x={x} currency={x.currency || p.currency} showCost />
                </li>
              ))}
            </ul>
          </Card>
        ))}
      </div>
    );
  }
  return (
    <div className="flex flex-col gap-6">
      {notes.length > 0 && (
        <section aria-labelledby="your-notes" className="flex flex-col gap-3">
          <h2 id="your-notes" className="text-[15px] font-semibold text-ink">
            Your notes <span className="font-normal text-muted">· {notes.length}</span>
          </h2>
          <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
            {notes.map((x) => (
              <NoteCard key={x.holding_code} x={x} currency={x.currency || p.currency} />
            ))}
          </div>
        </section>
      )}
      {others.length > 0 && (
        <Card>
          <CardHeader title="Other holdings" />
          <ul className="divide-y divide-border border-t border-border">
            {others.map((x) => (
              <li key={x.holding_code}>
                <HoldingRow x={x} currency={x.currency || p.currency} />
              </li>
            ))}
          </ul>
        </Card>
      )}
    </div>
  );
}

function NoteCard({ x, currency }: { x: BrokerPosition; currency: string }) {
  const n = x.note!;
  const called = calledNext(n.if_called_next);
  return (
    <Link
      to="/wealth/investments/$holdingCode"
      params={{ holdingCode: x.holding_code }}
      className="group tap block rounded-lg border border-border bg-surface p-4 transition-colors hover:border-border-strong focus-visible:border-accent sm:p-5"
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="text-[15px] font-semibold text-ink group-hover:text-accent">{x.name}</h3>
          {x.isin && <p className="mt-0.5 truncate text-[12px] text-muted">{x.isin}</p>}
        </div>
        <ChevronRight className="mt-0.5 size-4 shrink-0 text-subtle group-hover:text-ink-2" />
      </div>
      <VerdictText verdict={n.verdict} className="mt-2 text-[14px]" />
      <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2">
        <div className="min-w-0">
          <dt className="text-[12px] text-subtle">Worth today</dt>
          <dd className="tabular mt-0.5 text-[17px] font-medium text-ink">{formatTotal(x.value, { currency })}</dd>
        </div>
        {called ? (
          <div className="min-w-0">
            <dt className="text-[12px] text-subtle">If called on {verdictDate(called.obsDate)}</dt>
            <dd className="tabular mt-0.5 text-[17px] font-medium text-ink">{formatTotal(called.total, { currency })}</dd>
            <dd className="tabular text-[12px]">
              <span className={TONE_TEXT[signTone(called.profit)]}>{formatTotal(called.profit, { currency, signed: true })}</span>
              {called.annualisedPct && <span className="text-muted"> · {pct(called.annualisedPct, 0)} a year</span>}
            </dd>
          </div>
        ) : (
          <div className="min-w-0">
            <dt className="text-[12px] text-subtle">Paid</dt>
            <dd className="tabular mt-0.5 text-[17px] font-medium text-ink">{formatTotal(x.invested, { currency })}</dd>
          </div>
        )}
      </dl>
      <StockBars shares={n.underlyings} className="mt-4 border-t border-border pt-3" />
    </Link>
  );
}

function HoldingRow({ x, currency, showCost = false }: { x: BrokerPosition; currency: string; showCost?: boolean }) {
  const r = holdingResult(x);
  return (
    <Link
      to="/wealth/investments/$holdingCode"
      params={{ holdingCode: x.holding_code }}
      className="tap group flex items-center gap-3 px-5 py-3 hover:bg-surface-2/60 focus-visible:bg-surface-2/60"
    >
      {showCost ? (
        <span className="min-w-0 flex-1">
          <span className="block truncate text-[13px] font-medium text-ink">{x.name}</span>
          <span className="tabular block truncate text-[12px] text-muted">
            {formatUnits(x.quantity)} units · invested {formatTotal(x.cost, { currency })}
          </span>
        </span>
      ) : (
        <span className="min-w-0 flex-1 truncate text-[13px] font-medium text-ink">{x.name}</span>
      )}
      <span className="tabular text-right text-[13px]">
        <span className="block font-medium text-ink">{formatTotal(x.value, { currency })}</span>
        {r.profit !== null && (
          <span className={cn("block text-[12px]", TONE_TEXT[signTone(r.profit)])}>
            {formatTotal(r.profit, { currency, signed: true })}
            {r.returnPct && ` (${pct(r.returnPct, 1)})`}
          </span>
        )}
      </span>
      <ChevronRight className="size-4 shrink-0 text-subtle group-hover:text-ink-2" />
    </Link>
  );
}
