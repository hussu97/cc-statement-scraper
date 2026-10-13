import { Repeat } from "lucide-react";
import { useRecurring } from "@/data/analytics";
import type { RpcReturn } from "@/lib/supabase";
import { formatDate, todayDubai } from "@/lib/dates";
import { formatMoney } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Money } from "@/components/ledger";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Tooltip } from "@/components/ui/primitives";
import { EmptyState, LoadingRows, QueryView } from "@/components/ui/states";
import { cadenceLabel, countLabel, priceChangeBadge } from "./labels";

type Row = RpcReturn<"recurring_list">[number];

const PER: Record<string, string> = { weekly: "week", monthly: "month", yearly: "year" };

export function SubscriptionsTab({ profileCode }: { profileCode: string }) {
  const q = useRecurring(profileCode);
  return (
    <Card>
      <QueryView
        query={q}
        loading={<LoadingRows rows={6} />}
        isEmpty={(rows) => rows.length === 0}
        empty={
          <>
            <CardHeader title="Subscriptions" />
            <EmptyState icon={<Repeat />} title="Nothing recurring found yet">
              Bank Ledger needs 3 charges at a steady interval from the same merchant before it calls something a subscription.
            </EmptyState>
          </>
        }
      >
        {(rows) => {
          const active = rows.filter((r) => r.status === "active").length;
          const inactive = rows.length - active;
          return (
            <>
              <CardHeader
                title="Subscriptions"
                eyebrow={[countLabel(active, "active charge"), inactive ? `${inactive} ended or dismissed` : null].filter(Boolean).join(" · ")}
              />
              <ul className="divide-y divide-border border-t border-border">
                {rows.map((r) => (
                  <SubscriptionRow key={r.recurring_code} row={r} />
                ))}
              </ul>
              <p className="border-t border-border px-5 py-3 text-[12px] text-muted">
                Spotted from 3 or more charges at a steady interval. Annual cost is the expected charge over a year.
              </p>
            </>
          );
        }}
      </QueryView>
    </Card>
  );
}

function SubscriptionRow({ row }: { row: Row }) {
  const inactive = row.status !== "active";
  const change = priceChangeBadge(row.price_change);
  const overdue = !inactive && row.next_expected < todayDubai();
  return (
    <li className={cn("grid grid-cols-[1fr_auto] gap-x-4 gap-y-1 px-5 py-3.5 md:grid-cols-[minmax(0,1.6fr)_1fr_1fr_1fr]", inactive && "opacity-60")}>
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="truncate text-sm font-medium text-ink">{row.merchant_name}</span>
          {inactive && <Badge>{row.status === "ended" ? "Ended" : "Dismissed"}</Badge>}
        </div>
        <p className="mt-0.5 truncate text-[12px] text-muted">
          {cadenceLabel(row.cadence)}
          {row.category_name ? ` · ${row.category_name}` : ""} · {countLabel(row.occurrences, "charge")}
        </p>
      </div>

      <div className="text-right md:text-left">
        <p className="text-sm text-ink">
          <Money value={row.expected_amount} />
          <span className="text-[12px] text-muted"> / {PER[row.cadence] ?? "time"}</span>
        </p>
        <p className="mt-0.5 flex items-center justify-end gap-1.5 text-[12px] text-muted md:justify-start">
          Last <Money value={row.last_amount} />
          {change && (
            <Tooltip content={`Last charge vs the usual ${formatMoney(row.expected_amount)}`}>
              <Badge tone={change.tone} className="tabular">
                {change.label}
              </Badge>
            </Tooltip>
          )}
        </p>
      </div>

      <div className="text-[12px] text-muted md:text-sm">
        <span className="md:hidden">Next </span>
        <span className={cn("tabular", overdue ? "text-warn" : "md:text-ink-2")}>{inactive ? "—" : formatDate(row.next_expected, "short")}</span>
        <p className="hidden text-[12px] text-subtle md:block">{inactive ? `Last ${formatDate(row.last_date, "short")}` : overdue ? "Expected, not seen yet" : "Next expected"}</p>
      </div>

      <div className="text-right text-[12px] text-muted md:text-sm">
        <Money value={row.annual_cost} total className="md:text-ink-2" />
        <span className="md:hidden"> a year</span>
        <p className="hidden text-[12px] text-subtle md:block">a year</p>
      </div>
    </li>
  );
}
