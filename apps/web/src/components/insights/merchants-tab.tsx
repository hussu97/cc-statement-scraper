import { useMemo } from "react";
import { Link } from "@tanstack/react-router";
import { useMerchantLeaderboard } from "@/data/analytics";
import { useCategories } from "@/data/rules";
import type { RpcReturn } from "@/lib/supabase";
import { formatDate, type DateRange } from "@/lib/dates";
import { formatCount } from "@/lib/money";
import { Money } from "@/components/ledger";
import { Card, CardHeader, Dot } from "@/components/ui/display";
import { EmptyState, LoadingRows, QueryView } from "@/components/ui/states";
import { countLabel, rangeLabel } from "./labels";

type Row = RpcReturn<"merchant_leaderboard">[number];
const LIMIT = 50;

export function MerchantsTab({ profileCode, range }: { profileCode: string; range: DateRange }) {
  const q = useMerchantLeaderboard(profileCode, range, LIMIT);
  const cats = useCategories(profileCode);
  const tokenOf = useMemo(() => new Map((cats.data ?? []).map((c) => [c.category_code, c.color_token])), [cats.data]);

  return (
    <Card>
      <CardHeader eyebrow={rangeLabel(range.from, range.to)} title="Top merchants" />
      <QueryView
        query={q}
        loading={<LoadingRows rows={8} />}
        isEmpty={(rows) => rows.length === 0}
        empty={<EmptyState title="No merchants in this range">Pick a longer range to see where you shop most.</EmptyState>}
      >
        {(rows) => (
          <>
            {/* Desktop: table */}
            <div className="hidden md:block">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-y border-border text-left text-[11px] font-medium tracking-[0.06em] text-subtle uppercase">
                    <th className="w-10 py-2 pl-5 font-medium">#</th>
                    <th className="py-2 pr-3 font-medium">Merchant</th>
                    <th className="py-2 pr-3 font-medium">Category</th>
                    <th className="py-2 pr-3 text-right font-medium">Txns</th>
                    <th className="py-2 pr-3 text-right font-medium">Average</th>
                    <th className="py-2 pr-3 text-right font-medium">Total</th>
                    <th className="py-2 pr-5 text-right font-medium">Last</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {rows.map((r, i) => (
                    <tr key={r.merchant_code ?? `${r.merchant_name}-${i}`} className="transition-colors hover:bg-surface-2">
                      <td className="py-2.5 pl-5 text-[12px] text-subtle tabular">{i + 1}</td>
                      <td className="max-w-64 py-2.5 pr-3">
                        <MerchantLink row={r} range={range} className="block truncate text-ink hover:text-accent" />
                      </td>
                      <td className="py-2.5 pr-3">
                        <CategoryCell row={r} token={r.category_code ? tokenOf.get(r.category_code) : null} />
                      </td>
                      <td className="py-2.5 pr-3 text-right text-ink-2 tabular">{formatCount(r.txn_count)}</td>
                      <td className="py-2.5 pr-3 text-right text-ink-2">
                        <Money value={r.avg_amount} />
                      </td>
                      <td className="py-2.5 pr-3 text-right font-medium text-ink">
                        <Money value={r.amount} />
                      </td>
                      <td className="py-2.5 pr-5 text-right whitespace-nowrap text-muted tabular">{formatDate(r.last_date, "short")}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {/* Mobile: stacked rows */}
            <ul className="divide-y divide-border border-t border-border md:hidden">
              {rows.map((r, i) => (
                <li key={r.merchant_code ?? `${r.merchant_name}-${i}`} className="flex items-start gap-3 px-5 py-3">
                  <span className="w-5 pt-0.5 text-[12px] text-subtle tabular">{i + 1}</span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-baseline justify-between gap-3">
                      <MerchantLink row={r} range={range} className="-my-2.5 truncate py-2.5 text-sm text-ink" />
                      <Money value={r.amount} className="text-sm font-medium text-ink" />
                    </div>
                    <div className="mt-1 flex items-center justify-between gap-3 text-[12px] text-muted">
                      <CategoryCell row={r} token={r.category_code ? tokenOf.get(r.category_code) : null} />
                      <span className="tabular">{formatDate(r.last_date, "short")}</span>
                    </div>
                    <p className="mt-0.5 text-[12px] text-subtle">
                      {countLabel(r.txn_count, "transaction")} · avg <Money value={r.avg_amount} />
                    </p>
                  </div>
                </li>
              ))}
            </ul>
            {rows.length >= LIMIT && <p className="border-t border-border px-5 py-3 text-[12px] text-muted">Showing your top {LIMIT} merchants by spend.</p>}
          </>
        )}
      </QueryView>
    </Card>
  );
}

function MerchantLink({ row, range, className }: { row: Row; range: DateRange; className?: string }) {
  const name = row.merchant_name ?? "Unknown merchant";
  return (
    <Link to="/activity" search={{ q: name, from: range.from, to: range.to }} className={className} title={`See ${name} in Activity`}>
      {name}
    </Link>
  );
}

function CategoryCell({ row, token }: { row: Row; token: string | null | undefined }) {
  return (
    <span className="inline-flex min-w-0 items-center gap-1.5 text-[13px] text-ink-2">
      <Dot token={token} />
      <span className="truncate">{row.category_name ?? "Uncategorised"}</span>
    </span>
  );
}
