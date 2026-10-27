import type { ReactNode } from "react";
import { calledLabel, pct, returnText, type IfCalled, type SellToday } from "@/lib/notes";
import { formatDate } from "@/lib/dates";
import { formatMoney } from "@/lib/money";
import { signTone } from "@/lib/holdings";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";

// formatMoney writes the minus itself; a gain gets a plus.
const signed = (v: string, currency: string) => formatMoney(v, { currency, signed: true });
const TONE = { positive: "text-positive", danger: "text-danger", neutral: "text-ink-2" } as const;

/**
 * Sell the note today at the broker's bid, or hold it to its next autocall: the server's two
 * figures side by side (CLAUDE.md §2.2). Either side can be missing (no broker price yet, or no
 * autocall left), and says so.
 */
export function SellOrWait({ sell, called, currency }: { sell: SellToday | null; called: IfCalled | null; currency: string }) {
  return (
    <Card>
      <CardHeader eyebrow="Sell or hold" title="Today's price against the next call" />
      <div className="grid grid-cols-1 gap-3 px-5 pb-5 sm:grid-cols-2">
        <Panel title="Sell today">
          {sell ? (
            <>
              <Figure total={formatMoney(sell.total, { currency })} profit={signed(sell.profit, currency)} tone={signTone(sell.profit)} />
              <p className="mt-1 text-[12px] text-muted">
                {sell.pricePct ? `At the broker's bid of ${pct(sell.pricePct, 2)}` : "At the broker's price"}
                {sell.asOf ? ` on ${formatDate(sell.asOf)}` : ""}
                {sell.returnPct ? ` · ${returnText(sell.returnPct)}` : ""}, with coupons received
              </p>
            </>
          ) : (
            <p className="text-[13px] text-muted">No broker price yet.</p>
          )}
        </Panel>
        <Panel title={called ? calledLabel(called) : "If called"}>
          {called ? (
            <>
              <Figure total={formatMoney(called.total, { currency })} profit={signed(called.profit, currency)} tone={signTone(called.profit)} />
              <p className="mt-1 text-[12px] text-muted">
                {returnText(called.returnPct, called.annualisedPct)}
                {called.triggerPct ? ` · if every share is at ${pct(called.triggerPct)} or above on ${formatDate(called.obsDate)}` : ""}
              </p>
            </>
          ) : (
            <p className="text-[13px] text-muted">No autocall left: it runs to maturity.</p>
          )}
        </Panel>
      </div>
    </Card>
  );
}

function Panel({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="rounded-md bg-surface-2/60 px-4 py-3">
      <p className="text-[11px] font-medium tracking-[0.06em] text-subtle uppercase">{title}</p>
      <div className="mt-1">{children}</div>
    </div>
  );
}

function Figure({ total, profit, tone }: { total: string; profit: string; tone: keyof typeof TONE }) {
  return (
    <p className="tabular flex flex-wrap items-baseline gap-x-2">
      <span className="text-lg font-semibold text-ink">{total}</span>
      <span className={cn("text-[13px] font-medium", TONE[tone])}>{profit}</span>
    </p>
  );
}

/** The two figures in one compact cell, for a table or a list row. */
export function SellOrWaitInline({ sell, called, currency }: { sell: SellToday | null; called: IfCalled | null; currency: string }) {
  return (
    <div className="flex flex-col gap-0.5 text-[12px]">
      {sell && (
        <span className="tabular whitespace-nowrap">
          <span className="text-muted">Sell today </span>
          <span className={cn("font-medium", TONE[signTone(sell.profit)])}>{signed(sell.profit, currency)}</span>
        </span>
      )}
      {called && (
        <span className="tabular whitespace-nowrap">
          <span className="text-muted">{calledLabel(called, "short")} </span>
          <span className={cn("font-medium", TONE[signTone(called.profit)])}>{signed(called.profit, currency)}</span>
        </span>
      )}
    </div>
  );
}
