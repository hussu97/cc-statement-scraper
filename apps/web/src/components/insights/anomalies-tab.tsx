import { Link } from "@tanstack/react-router";
import { ChevronRight, ShieldCheck } from "lucide-react";
import { useAnomalies } from "@/data/analytics";
import type { RpcReturn } from "@/lib/supabase";
import { formatDate, type DateRange } from "@/lib/dates";
import { formatMoney, toAmount } from "@/lib/money";
import { Money } from "@/components/ledger";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { EmptyState, LoadingRows, QueryView } from "@/components/ui/states";
import { anomalyReasonLabel, countLabel, rangeLabel } from "./labels";

type Row = RpcReturn<"anomalies">[number];

export function AnomaliesTab({ profileCode, range }: { profileCode: string; range: DateRange }) {
  const q = useAnomalies(profileCode, range);
  return (
    <Card>
      <QueryView
        query={q}
        loading={<LoadingRows rows={5} />}
        isEmpty={(rows) => rows.length === 0}
        empty={
          <>
            <CardHeader eyebrow={rangeLabel(range.from, range.to)} title="Unusual spending" />
            <EmptyState icon={<ShieldCheck />} title="Nothing unusual in this range">
              Ledger flags charges far above what you normally spend at a merchant or in a category, and large first purchases.
            </EmptyState>
          </>
        }
      >
        {(rows) => (
          <>
            <CardHeader eyebrow={rangeLabel(range.from, range.to)} title={`Unusual spending · ${countLabel(rows.length, "charge")}`} />
            <ul className="divide-y divide-border border-t border-border">
              {rows.map((r) => (
                <AnomalyRow key={r.txn_code} row={r} />
              ))}
            </ul>
            <p className="border-t border-border px-5 py-3 text-[12px] text-muted">
              Compared with the 12 months before each charge. “Usually” is the average, ± one standard deviation.
            </p>
          </>
        )}
      </QueryView>
    </Card>
  );
}

function AnomalyRow({ row }: { row: Row }) {
  const scope = row.reason === "merchant_outlier" ? "at this merchant" : "in this category";
  const hasBaseline = toAmount(row.baseline_mean) !== null;
  return (
    <li>
      <Link
        to="/activity"
        search={{ txn: row.txn_code, from: row.txn_date, to: row.txn_date }}
        className="group flex items-center gap-3 px-5 py-3.5 transition-colors hover:bg-surface-2"
      >
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline justify-between gap-3">
            <span className="truncate text-sm text-ink">{row.description}</span>
            <Money value={row.amount} className="text-sm font-medium text-ink" />
          </div>
          <div className="mt-1 flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
            <span className="flex items-center gap-2 text-[12px] text-muted">
              <span className="tabular">{formatDate(row.txn_date, "short")}</span>
              <Badge tone="warn">{anomalyReasonLabel(row.reason)}</Badge>
            </span>
            {hasBaseline && (
              <span className="text-[12px] text-muted">
                Usually <span className="tabular">{formatMoney(row.baseline_mean)}</span>
                {toAmount(row.baseline_sd) !== null && <span className="tabular"> ± {formatMoney(row.baseline_sd, { bare: true })}</span>} {scope}
              </span>
            )}
          </div>
        </div>
        <ChevronRight className="size-4 shrink-0 text-subtle transition-transform group-hover:translate-x-0.5" aria-hidden />
      </Link>
    </li>
  );
}
