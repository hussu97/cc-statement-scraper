import { History } from "lucide-react";
import { basisWords, heldMonths, pastHeadline, type BrokerPortfolio, type ClosedPosition } from "@/lib/broker";
import { pct } from "@/lib/notes";
import { signTone } from "@/lib/holdings";
import { formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { EmptyState } from "@/components/ui/states";
import { TONE_TEXT } from "./broker-portfolio";
import { HoldingRowShell } from "./broker-holdings";

/**
 * The Past notes tab: what everything that ended came to, then one line per note or position.
 * `linked` (default) links each to its Wealth page; India passes false.
 */
export function PastNotesTab({ portfolio: p, linked = true }: { portfolio: BrokerPortfolio; linked?: boolean }) {
  const headline = pastHeadline(p.closed_total, p.closed, p.currency);
  if (p.closed.length === 0) {
    return (
      <Card>
        <EmptyState icon={<History />} title={p.basis === "cost" ? "Nothing sold yet" : "Nothing has ended yet"}>
          {basisWords(p.basis).ended}
        </EmptyState>
      </Card>
    );
  }
  return (
    <Card>
      <CardHeader title={headline ?? basisWords(p.basis).past} />
      <ul className="divide-y divide-border border-t border-border">
        {p.closed.map((x) => (
          <li key={x.holding_code}>
            <PastRow x={x} currency={p.currency} linked={linked} />
          </li>
        ))}
      </ul>
    </Card>
  );
}

function PastRow({ x, currency, linked }: { x: ClosedPosition; currency: string; linked: boolean }) {
  const returns = [x.return_pct ? pct(x.return_pct, 1) : null, x.annualised_pct ? `${pct(x.annualised_pct, 0)} a year` : null].filter(Boolean).join(" · ");
  return (
    <HoldingRowShell holdingCode={x.holding_code} linked={linked}>
      <div className="min-w-0 flex-1">
        <p className="truncate text-[13px] font-medium text-ink">{x.name}</p>
        <p className="mt-0.5 text-[12px] text-muted">{heldMonths(x)}</p>
      </div>
      <div className="tabular text-right">
        <p className={cn("text-[13px] font-medium", TONE_TEXT[signTone(x.profit)])}>{formatTotal(x.profit, { currency, signed: true })}</p>
        {returns && <p className="text-[12px] text-muted">{returns}</p>}
      </div>
    </HoldingRowShell>
  );
}
