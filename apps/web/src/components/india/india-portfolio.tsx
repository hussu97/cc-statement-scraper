import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { BriefcaseBusiness, ChevronRight, Repeat } from "lucide-react";
import { segmentHolds, type BrokerPortfolio, type BrokerPosition, type HighlightItem, type Sip } from "@/lib/broker";
import { allocationBars, POSITION_SORT_LABEL, POSITION_SORTS, positionLine, sipSchedule, sipStatus, sipStepUp, sortPositions, type PositionSort } from "@/lib/broker-detail";
import { formatUnits } from "@/lib/investments";
import { formatPct, signTone } from "@/lib/holdings";
import { formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import type { IndiaSegment } from "@/lib/india";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Segmented } from "@/components/ui/segmented";
import { EmptyState } from "@/components/ui/states";
import { TONE_TEXT } from "@/components/wealth/broker-portfolio";

// Zerodha Kite and Coin in detail (tasks/todo.md §14): where the money sits, what stands out,
// Coin's SIPs, and every position, sortable, each linking to its own page. Figures are
// broker_portfolio's; the view only lays them out.

const Signed = ({ value, currency }: { value: string | null | undefined; currency: string }) => (
  <span className={TONE_TEXT[signTone(value)]}>{formatTotal(value, { currency, signed: true })}</span>
);

const PctText = ({ value, className }: { value: string | null | undefined; className?: string }) => {
  const t = formatPct(value, { signed: true });
  return t ? <span className={cn(TONE_TEXT[signTone(value)], className)}>{t}</span> : <span className={cn("text-subtle", className)}>—</span>;
};

/** Where the money sits: a bar of slices, then a line each. Coin can switch to fund houses. */
export function AllocationCard({ portfolio: p }: { portfolio: BrokerPortfolio }) {
  const [by, setBy] = useState<"type" | "house">("type");
  const c = p.currency;
  const houses = p.issuers.length > 0;
  const slices =
    by === "house" && houses
      ? allocationBars(p.issuers.map((h) => ({ key: h.issuer, label: h.issuer, positions: h.positions, value: h.value, weight_pct: h.weight_pct, invested: null, profit: null, return_pct: null })))
      : allocationBars(p.allocation);
  if (p.allocation.length === 0) return null;
  return (
    <Card>
      <CardHeader
        title="Allocation"
        action={
          houses ? (
            <Segmented
              ariaLabel="Allocation by"
              value={by}
              onChange={setBy}
              options={[
                { value: "type", label: "Type" },
                { value: "house", label: "Fund house" },
              ]}
            />
          ) : undefined
        }
      />
      <div className="px-5 pb-4">
        <div className="flex h-2.5 w-full overflow-hidden rounded-pill bg-surface-2" aria-hidden>
          {slices.map((s) => (
            <span key={s.key} className="h-full" style={{ width: `${s.width}%`, background: s.color }} />
          ))}
        </div>
        <ul className="mt-3 flex flex-col gap-2">
          {slices.map((s) => (
            <li key={s.key} className="flex items-baseline gap-2 text-[13px]">
              <span aria-hidden className="inline-block size-2.5 shrink-0 translate-y-[1px] rounded-[3px]" style={{ background: s.color }} />
              <span className="min-w-0 flex-1 truncate text-ink">
                {s.label}
                {s.positions && <span className="text-muted"> · {s.positions}</span>}
              </span>
              <span className="tabular w-14 text-right text-muted">{formatPct(s.weight_pct) ?? "—"}</span>
              <span className="tabular w-28 text-right font-medium text-ink">{formatTotal(s.value, { currency: c })}</span>
              {by === "type" && (
                <span className="tabular hidden w-16 text-right sm:inline">
                  <PctText value={s.return_pct} />
                </span>
              )}
            </li>
          ))}
        </ul>
      </div>
    </Card>
  );
}

function HighlightList({ title, items, field, segment, currency }: { title: string; items: HighlightItem[]; field: "return" | "today"; segment: IndiaSegment; currency: string }) {
  if (items.length === 0) return null;
  return (
    <div className="min-w-0">
      <h3 className="text-[12px] text-subtle">{title}</h3>
      <ul className="mt-1 flex flex-col">
        {items.map((h) => (
          <li key={h.isin ?? h.name}>
            <Link
              to={segment === "kite" ? "/india/kite/$isin" : "/india/coin/$isin"}
              params={{ isin: h.isin ?? "" }}
              className="tap flex items-baseline gap-2 rounded-sm py-1 text-[13px] hover:text-accent"
            >
              <span className="min-w-0 flex-1 truncate text-ink">{h.name}</span>
              {field === "today" ? (
                <span className="tabular whitespace-nowrap">
                  <Signed value={h.day_change} currency={currency} /> <PctText value={h.day_change_pct} className="text-[12px]" />
                </span>
              ) : (
                <PctText value={h.return_pct} className="tabular whitespace-nowrap" />
              )}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Best and worst by return, today's biggest moves, and how concentrated the account is. */
export function HighlightsCard({ portfolio: p, segment }: { portfolio: BrokerPortfolio; segment: IndiaSegment }) {
  const h = p.highlights;
  if (!h) return null;
  const any = h.best.length + h.worst.length + h.gainers_today.length + h.losers_today.length > 0;
  if (!any) return null;
  const c = p.currency;
  return (
    <Card>
      <CardHeader title="Highlights" />
      <div className="grid grid-cols-1 gap-x-6 gap-y-4 px-5 pb-4 sm:grid-cols-2">
        <HighlightList title="Best since bought" items={h.best} field="return" segment={segment} currency={c} />
        <HighlightList title="Worst since bought" items={h.worst} field="return" segment={segment} currency={c} />
        <HighlightList title="Up most today" items={h.gainers_today} field="today" segment={segment} currency={c} />
        <HighlightList title="Down most today" items={h.losers_today} field="today" segment={segment} currency={c} />
      </div>
      {h.top5_weight_pct && (
        <p className="border-t border-border px-5 py-3 text-[12px] text-muted">
          The five largest positions are <span className="tabular font-medium text-ink">{formatPct(h.top5_weight_pct)}</span> of the account.
        </p>
      )}
    </Card>
  );
}

function SipRow({ s }: { s: Sip }) {
  const status = sipStatus(s);
  const stepUp = sipStepUp(s.step_up);
  const inner = (
    <>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[13px] font-medium text-ink">{s.fund}</span>
        <span className="tabular block text-[12px] text-muted">
          {sipSchedule(s)}
          {stepUp && ` · ${stepUp}`}
        </span>
        <span className={cn("block text-[12px]", status.tone === "danger" ? "text-danger" : status.tone === "positive" ? "text-ink-2" : "text-subtle")}>{status.text}</span>
      </span>
      {s.missed && <Badge tone="danger">Missed</Badge>}
      {s.status === "paused" && <Badge>Paused</Badge>}
    </>
  );
  return <li className="flex items-start gap-3 px-5 py-3">{inner}</li>;
}

/** Coin's SIPs: active first, a rejected instalment flagged. */
export function SipsCard({ sips }: { sips: Sip[] }) {
  const shown = sips.filter((s) => s.status !== "cancelled" || s.missed);
  if (shown.length === 0) return null;
  const missed = shown.filter((s) => s.missed).length;
  return (
    <Card>
      <CardHeader
        title={
          <span className="inline-flex items-center gap-2">
            <Repeat className="size-4 text-subtle" aria-hidden /> SIPs
          </span>
        }
        action={missed > 0 ? <Badge tone="danger">{missed === 1 ? "1 instalment missed" : `${missed} instalments missed`}</Badge> : undefined}
      />
      <ul className="divide-y divide-border border-t border-border">
        {shown.map((s) => (
          <SipRow key={s.sip_code} s={s} />
        ))}
      </ul>
    </Card>
  );
}

/** On a phone the row has room for one more figure: the one the list is sorted by (P&L otherwise). */
function CompactFigure({ x, currency, sort }: { x: BrokerPosition; currency: string; sort: PositionSort }) {
  if (sort === "today")
    return x.day_change ? (
      <>
        <Signed value={x.day_change} currency={currency} /> <PctText value={x.day_change_pct} /> today
      </>
    ) : (
      <span className="text-subtle">No move yet today</span>
    );
  if (sort === "weight") return <span className="text-muted">{formatPct(x.weight_pct) ?? "—"} of the account</span>;
  return (
    <>
      <Signed value={x.profit} currency={currency} /> <PctText value={x.return_pct} />
    </>
  );
}

function PositionRow({ x, currency, segment, sort }: { x: BrokerPosition; currency: string; segment: IndiaSegment; sort: PositionSort }) {
  return (
    <Link
      to={segment === "kite" ? "/india/kite/$isin" : "/india/coin/$isin"}
      params={{ isin: x.isin ?? "" }}
      className="tap group grid grid-cols-[1fr_auto] items-center gap-x-3 gap-y-0.5 px-5 py-3 hover:bg-surface-2/60 focus-visible:bg-surface-2/60 xl:grid-cols-[minmax(0,1fr)_5rem_6.5rem_6.5rem_7rem_4.5rem_1rem]"
    >
      <span className="min-w-0">
        <span className="block truncate text-[13px] font-medium text-ink group-hover:text-accent">{x.name}</span>
        <span className="tabular block truncate text-[12px] text-muted">
          {positionLine(x)}
          <span className="xl:hidden"> · {formatUnits(x.quantity)} units</span>
        </span>
      </span>
      <span className="tabular hidden text-right text-[12px] text-muted xl:block">{formatUnits(x.quantity)}</span>
      <span className="tabular hidden text-right text-[12px] text-muted xl:block">{formatTotal(x.cost, { currency })}</span>
      <span className="tabular row-span-2 text-right text-[13px] xl:row-span-1">
        <span className="block font-medium text-ink">{formatTotal(x.value, { currency })}</span>
        <span className="block text-[12px] xl:hidden">
          <CompactFigure x={x} currency={currency} sort={sort} />
        </span>
      </span>
      <span className="tabular hidden text-right text-[12px] xl:block">
        <Signed value={x.profit} currency={currency} />
        <PctText value={x.return_pct} className="block" />
      </span>
      <span className="tabular hidden text-right text-[12px] xl:block">
        <PctText value={x.day_change_pct} />
      </span>
      <ChevronRight className="hidden size-4 text-subtle group-hover:text-ink-2 xl:block" aria-hidden />
    </Link>
  );
}

/** Every open position, sortable, each to its own page. */
export function PositionsCard({ portfolio: p, segment, sort, onSort }: { portfolio: BrokerPortfolio; segment: IndiaSegment; sort: PositionSort; onSort: (s: PositionSort) => void }) {
  if (p.positions.length === 0) {
    return (
      <Card>
        <EmptyState icon={<BriefcaseBusiness />} title="No open positions">
          The last sync found nothing held in this account.
        </EmptyState>
      </Card>
    );
  }
  const rows = sortPositions(p.positions, sort);
  return (
    <Card>
      <CardHeader
        title={`${segmentHolds(segment)} · ${p.positions.length}`}
        action={<Segmented ariaLabel="Sort by" value={sort} onChange={onSort} options={POSITION_SORTS.map((s) => ({ value: s, label: POSITION_SORT_LABEL[s] }))} className="max-w-full overflow-x-auto" />}
        className="flex-wrap"
      />
      <div className="tabular hidden grid-cols-[minmax(0,1fr)_5rem_6.5rem_6.5rem_7rem_4.5rem_1rem] gap-x-3 border-t border-border px-5 py-2 text-right text-[11px] text-subtle xl:grid">
        <span className="text-left">Name</span>
        <span>Units</span>
        <span>Invested</span>
        <span>Value</span>
        <span>P&amp;L</span>
        <span>Today</span>
        <span />
      </div>
      <ul className="divide-y divide-border border-t border-border">
        {rows.map((x) => (
          <li key={x.holding_code}>
            <PositionRow x={x} currency={x.currency || p.currency} segment={segment} sort={sort} />
          </li>
        ))}
      </ul>
    </Card>
  );
}
