import { Coins, Plus } from "lucide-react";
import type { Holding, useHoldingsValuation } from "@/data/holdings";
import { formatPct, formatWeight, holdingKind, quoteLabel, signTone } from "@/lib/holdings";
import { formatDate, formatRelative } from "@/lib/dates";
import { formatMoney, formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { ViewerNote } from "@/components/rules/shared";
import { SignedTotal, TONE_TEXT } from "./investments";
import { HoldingImage } from "./holding-image";

/** The ledger's gold and silver, each with its value, gain, 24-hour change and the price used. */
export function HoldingsListCard({
  q,
  isOwner,
  onAdd,
  onEdit,
  onClose,
}: {
  q: ReturnType<typeof useHoldingsValuation>;
  isOwner: boolean;
  onAdd: () => void;
  onEdit: (h: Holding) => void;
  onClose: (h: Holding) => void;
}) {
  return (
    <Card>
      <CardHeader
        eyebrow="What you hold"
        title="Holdings"
        action={
          isOwner && (
            <Button size="sm" icon={<Plus className="size-3.5" />} onClick={onAdd}>
              <span className="sm:hidden">Add</span>
              <span className="hidden sm:inline">Add holding</span>
            </Button>
          )
        }
      />
      {!isOwner && <ViewerNote className="px-5 pb-3" />}
      {q.isLoading ? (
        <LoadingRows rows={3} />
      ) : q.isError || !q.data ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : q.data.holdings.length === 0 ? (
        <EmptyState
          icon={<Coins />}
          title="No gold or silver yet"
          action={
            isOwner ? (
              <Button size="sm" variant="primary" icon={<Plus className="size-3.5" />} onClick={onAdd}>
                Add holding
              </Button>
            ) : undefined
          }
        >
          {isOwner
            ? "Add a bar, coins or jewellery by weight. Bank Ledger values it at Dubai's retail rates and counts it in your net worth."
            : "The ledger's owner can add gold and silver here."}
        </EmptyState>
      ) : (
        <ul className="divide-y divide-border border-t border-border">
          {q.data.holdings.map((h) => (
            <HoldingRow key={h.holding_code} h={h} onEdit={isOwner ? () => onEdit(h) : undefined} onClose={isOwner ? () => onClose(h) : undefined} />
          ))}
        </ul>
      )}
    </Card>
  );
}

function HoldingRow({ h, onEdit, onClose }: { h: Holding; onEdit?: () => void; onClose?: () => void }) {
  const gainPct = formatPct(h.gain_pct, { signed: true });
  return (
    <li className="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:gap-4">
      <div className="flex min-w-0 flex-1 items-start gap-3">
      <HoldingImage imagePath={h.image_path} metal={h.metal} form={h.form} />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium text-ink">{h.name}</p>
        <p className="mt-0.5 text-[12px] text-ink-2">
          {holdingKind(h)} · {formatWeight(h.grams)}
        </p>
        <p className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-subtle">
          {h.aed_per_gram === null ? (
            <span>No {quoteLabel(h.quote).toLowerCase()} price yet</span>
          ) : (
            <span className="whitespace-nowrap">
              {quoteLabel(h.quote)} at {formatMoney(h.aed_per_gram)}/g, {formatRelative(h.price_as_of)}
            </span>
          )}
          {h.price_is_stale && <Badge tone="warn">Stale price</Badge>}
          {h.acquired_on && <span className="whitespace-nowrap">bought {formatDate(h.acquired_on)}</span>}
        </p>
        {h.notes && <p className="mt-1 text-[12px] [overflow-wrap:anywhere] text-muted">{h.notes}</p>}
      </div>
      </div>
      <div className="flex shrink-0 flex-col gap-0.5 pl-15 sm:items-end sm:pl-0 sm:text-right">
        <p className={cn("tabular text-sm", h.value_aed === null ? "text-muted" : "font-medium text-ink")}>{h.value_aed === null ? "No value yet" : formatTotal(h.value_aed)}</p>
        <p className="text-[12px]">
          {h.gain_aed === null ? (
            <span className="text-subtle">{h.cost_aed === null ? "No cost recorded" : "Gain not known yet"}</span>
          ) : (
            <span className={cn("tabular", TONE_TEXT[signTone(h.gain_aed)])}>
              {formatTotal(h.gain_aed, { signed: true })}
              {gainPct && ` (${gainPct})`}
            </span>
          )}
        </p>
        {h.change_24h_aed !== null && (
          <p className="text-[11px] text-subtle">
            <SignedTotal value={h.change_24h_aed} /> 24h
          </p>
        )}
        {(onEdit || onClose) && (
          <div className="mt-1 flex gap-4 sm:justify-end">
            {onEdit && (
              <Button size="sm" variant="link" className="text-[12px]" onClick={onEdit} aria-label={`Edit ${h.name}`}>
                Edit
              </Button>
            )}
            {onClose && (
              <Button size="sm" variant="link" className="text-[12px] text-muted" onClick={onClose} aria-label={`Close ${h.name}`}>
                Close
              </Button>
            )}
          </div>
        )}
      </div>
    </li>
  );
}
