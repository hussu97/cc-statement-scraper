import { Plane } from "lucide-react";
import { useFxSpend } from "@/data/analytics";
import type { RpcReturn } from "@/lib/supabase";
import type { DateRange } from "@/lib/dates";
import { formatCount, formatPercent, formatRate, formatTotal, toAmount } from "@/lib/money";
import { Money } from "@/components/ledger";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Tooltip } from "@/components/ui/primitives";
import { EmptyState, LoadingRows, QueryView } from "@/components/ui/states";
import { countLabel, rangeLabel } from "./labels";

type Row = RpcReturn<"fx_spend">[number];

export function FxTab({ profileCode, range }: { profileCode: string; range: DateRange }) {
  const q = useFxSpend(profileCode, range);
  return (
    <Card>
      <CardHeader eyebrow={rangeLabel(range.from, range.to)} title="Foreign-currency spending" />
      <QueryView
        query={q}
        loading={<LoadingRows rows={4} />}
        isEmpty={(rows) => rows.length === 0}
        empty={
          <EmptyState icon={<Plane />} title="No foreign-currency spending in this range">
            Purchases in other currencies show up here with the rate you effectively paid.
          </EmptyState>
        }
      >
        {(rows) => (
          <>
            <div className="hidden md:block">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-y border-border text-left text-[11px] font-medium tracking-[0.06em] text-subtle uppercase">
                    <th className="py-2 pl-5 font-medium">Currency</th>
                    <th className="py-2 pr-3 text-right font-medium">Spent</th>
                    <th className="py-2 pr-3 text-right font-medium">In AED</th>
                    <th className="py-2 pr-3 text-right font-medium">Txns</th>
                    <th className="py-2 pr-3 text-right font-medium">Rate paid</th>
                    <th className="py-2 pr-5 text-right font-medium" />
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {rows.map((r) => (
                    <tr key={r.currency}>
                      <td className="py-2.5 pl-5 font-medium text-ink">{r.currency}</td>
                      <td className="py-2.5 pr-3 text-right text-ink-2">
                        <Money value={r.amount_original} currency={r.currency} total />
                      </td>
                      <td className="py-2.5 pr-3 text-right font-medium text-ink">
                        <Money value={r.amount_aed} total />
                      </td>
                      <td className="py-2.5 pr-3 text-right text-ink-2 tabular">{formatCount(r.txn_count)}</td>
                      <td className="py-2.5 pr-3 text-right text-ink-2 tabular">{formatRate(r.implied_rate)}</td>
                      <td className="py-2.5 pr-5 text-right">
                        <EstimateBadge row={r} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <ul className="divide-y divide-border border-t border-border md:hidden">
              {rows.map((r) => (
                <li key={r.currency} className="px-5 py-3">
                  <div className="flex items-baseline justify-between gap-3">
                    <span className="text-sm font-medium text-ink">{r.currency}</span>
                    <Money value={r.amount_aed} total className="text-sm font-medium text-ink" />
                  </div>
                  <div className="mt-1 flex items-center justify-between gap-3 text-[12px] text-muted">
                    <Money value={r.amount_original} currency={r.currency} total />
                    <span className="tabular">1 {r.currency} = {formatRate(r.implied_rate)} AED</span>
                  </div>
                  <div className="mt-1 flex items-center justify-between gap-3 text-[12px] text-subtle">
                    <span>{countLabel(r.txn_count, "transaction")}</span>
                    <EstimateBadge row={r} />
                  </div>
                </li>
              ))}
            </ul>
            <p className="border-t border-border px-5 py-3 text-[12px] text-muted">
              Rate paid is AED per unit of foreign currency, as charged to your card. Estimated amounts use a reference rate until the statement shows what the bank charged.
            </p>
          </>
        )}
      </QueryView>
    </Card>
  );
}

function EstimateBadge({ row }: { row: Row }) {
  const share = toAmount(row.estimated_share) ?? 0;
  if (share <= 0) return null;
  return (
    <Tooltip content={`${formatPercent(share)} of these transactions use an estimated rate; ${formatTotal(row.amount_aed)} may move when statements arrive.`}>
      <Badge tone="info" className="tabular">
        {share >= 1 ? "Estimated" : `${formatPercent(share)} estimated`}
      </Badge>
    </Tooltip>
  );
}
