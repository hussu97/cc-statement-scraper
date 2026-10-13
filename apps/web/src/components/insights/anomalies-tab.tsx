import { Link } from "@tanstack/react-router";
import { Check, ChevronRight, ShieldCheck } from "lucide-react";
import { useAnomalies, useDismissAnomaly } from "@/data/analytics";
import { errorMessage } from "@/data/api";
import { useActiveProfile } from "@/data/profile";
import type { RpcReturn } from "@/lib/supabase";
import { formatDate, type DateRange } from "@/lib/dates";
import { Money } from "@/components/ledger";
import { Button } from "@/components/ui/button";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { EmptyState, LoadingRows, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { anomalyExplanation, anomalyReasonLabel, countLabel, rangeLabel } from "./labels";

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
              Bank Ledger flags charges far above what you normally spend at a merchant or in a category, and large first purchases.
            </EmptyState>
          </>
        }
      >
        {(rows) => (
          <>
            <CardHeader eyebrow={rangeLabel(range.from, range.to)} title={`Unusual spending · ${countLabel(rows.length, "charge")}`} />
            <ul className="divide-y divide-border border-t border-border">
              {rows.map((r) => (
                <AnomalyRow key={r.txn_code} row={r} profileCode={profileCode} />
              ))}
            </ul>
            <p className="border-t border-border px-5 py-3 text-[12px] text-muted">
              Each charge is compared with your purchases in the 12 months before it. Mark a charge as fine and it won't be flagged again.
            </p>
          </>
        )}
      </QueryView>
    </Card>
  );
}

function AnomalyRow({ row, profileCode }: { row: Row; profileCode: string }) {
  const { isOwner } = useActiveProfile();
  const dismiss = useDismissAnomaly(profileCode);
  const toast = useToast();
  const name = row.merchant_name ?? row.description;
  const fine = () =>
    dismiss.mutate(row.txn_code, {
      onSuccess: () => toast({ title: "Marked as fine", description: `${name} won't be flagged again.`, tone: "positive" }),
      onError: (e) => toast({ title: "Couldn't mark it as fine", description: errorMessage(e), tone: "danger" }),
    });
  return (
    <li className="flex items-center gap-2 pr-3">
      <Link
        to="/activity"
        search={{ txn: row.txn_code, from: row.txn_date, to: row.txn_date }}
        className="group flex min-w-0 flex-1 items-center gap-3 py-3.5 pl-5 transition-colors hover:bg-surface-2"
      >
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline justify-between gap-3">
            <span className="truncate text-sm text-ink">{name}</span>
            <Money value={row.amount} className="text-sm font-medium text-ink" />
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-muted">
            <span className="tabular">{formatDate(row.txn_date, "short")}</span>
            <Badge tone="warn">{anomalyReasonLabel(row.reason)}</Badge>
            <span>{anomalyExplanation(row)}</span>
          </div>
        </div>
        <ChevronRight className="size-4 shrink-0 text-subtle transition-transform group-hover:translate-x-0.5" aria-hidden />
      </Link>
      {isOwner && (
        // Phones show the check alone, so the merchant name keeps the row's width.
        <Button size="sm" variant="ghost" icon={<Check className="size-3.5" />} loading={dismiss.isPending} onClick={fine} aria-label={`This is fine: ${name}`} title="This is fine">
          <span className="hidden sm:inline">This is fine</span>
        </Button>
      )}
    </li>
  );
}
