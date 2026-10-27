import { Link } from "@tanstack/react-router";
import { Coins, Plus } from "lucide-react";
import type { Holding, useHoldingsValuation } from "@/data/holdings";
import { formatPct, formatWeight, holdingKind, quoteLabel, signTone } from "@/lib/holdings";
import { aedEquivalent, formatOwnValue, groupHoldings, investmentFacts, kindOf, linkRuleText, noValueText, valueInput } from "@/lib/investments";
import { formatDate, formatRelative } from "@/lib/dates";
import { formatMoney, formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { ViewerNote } from "@/components/rules/shared";
import { SignedTotal, TONE_TEXT } from "./investments";
import { HoldingAvatar, KindIcon } from "./holding-image";

export interface HoldingActions {
  onEdit?: (h: Holding) => void;
  onClose?: (h: Holding) => void;
  onUpdateValue?: (h: Holding) => void;
}

/** Every holding, grouped by kind, each with its value (own currency and AED), its date, cost and gain. */
export function HoldingsListCard({
  q,
  isOwner,
  onAdd,
  actions,
}: {
  q: ReturnType<typeof useHoldingsValuation>;
  isOwner: boolean;
  onAdd: () => void;
  actions: HoldingActions;
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
          title="No investments yet"
          action={
            isOwner ? (
              <Button size="sm" variant="primary" icon={<Plus className="size-3.5" />} onClick={onAdd}>
                Add holding
              </Button>
            ) : undefined
          }
        >
          {isOwner
            ? "Add gold or silver, a savings plan, a broker account, shares or a fixed deposit. Bank Ledger values them and counts them in your net worth."
            : "The ledger's owner can add investments here."}
        </EmptyState>
      ) : (
        <div className="border-t border-border">
          {groupHoldings(q.data.holdings).map((g) => (
            <section key={g.kind} aria-labelledby={`holdings-${g.kind}`}>
              <h3 id={`holdings-${g.kind}`} className="flex items-center gap-1.5 border-b border-border bg-surface-2/50 px-5 py-1.5 text-[11px] font-medium tracking-[0.06em] text-subtle uppercase">
                <KindIcon kind={g.kind} className="size-3.5" />
                {g.label}
              </h3>
              <ul className="divide-y divide-border border-b border-border">
                {g.holdings.map((h) => (
                  <HoldingRow key={h.holding_code} h={h} actions={isOwner ? actions : {}} />
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}
    </Card>
  );
}

/** The line under a holding's name: a metal's karat and weight, else its institution and terms. */
export function holdingFacts(h: Holding): string {
  return kindOf(h) === "metal" ? `${holdingKind({ ...h, metal: h.metal ?? "gold" })} · ${formatWeight(h.grams)}` : investmentFacts(h);
}

/** Where the value comes from and how fresh it is. */
export function ValueSource({ h }: { h: Holding }) {
  const kind = kindOf(h);
  return (
    <span className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-subtle">
      {kind === "metal" ? (
        h.aed_per_gram === null ? (
          <span>No {quoteLabel(h.quote).toLowerCase()} price yet</span>
        ) : (
          <span className="whitespace-nowrap">
            {quoteLabel(h.quote)} at {formatMoney(h.aed_per_gram)}/g, {formatRelative(h.price_as_of)}
          </span>
        )
      ) : h.value_as_of ? (
        <span className="whitespace-nowrap">
          {h.is_estimate ? "accrued to" : "value as of"} {formatDate(h.value_as_of.slice(0, 10))}
        </span>
      ) : valueInput(kind) ? (
        <span>No value recorded yet</span>
      ) : null}
      {h.price_is_stale && <Badge tone="warn">{kind === "metal" ? "Stale price" : "Out of date"}</Badge>}
      {h.is_estimate && <Badge tone="info">Estimated</Badge>}
      {kind === "metal" && h.acquired_on && <span className="whitespace-nowrap">bought {formatDate(h.acquired_on)}</span>}
    </span>
  );
}

function HoldingRow({ h, actions }: { h: Holding; actions: HoldingActions }) {
  const gainPct = formatPct(h.gain_pct, { signed: true });
  const kind = kindOf(h);
  const own = h.currency && h.currency !== "AED" ? formatOwnValue(h.value, h.currency) : null;
  const aed = aedEquivalent(h.value_aed, h.currency);
  // A structured note is changed from its own page (cancel_structured_note), never the holding form.
  const { onEdit, onClose, onUpdateValue } = kind === "structured_note" ? ({} as HoldingActions) : actions;
  return (
    <li className="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:gap-4">
      <div className="flex min-w-0 flex-1 items-start gap-3">
        <HoldingAvatar h={h} />
        <div className="min-w-0 flex-1">
          <Link
            to="/wealth/investments/$holdingCode"
            params={{ holdingCode: h.holding_code }}
            className="block truncate text-sm font-medium text-ink hover:text-accent hover:underline"
          >
            {h.name}
          </Link>
          <p className="mt-0.5 text-[12px] text-ink-2">{holdingFacts(h)}</p>
          <p className="mt-0.5">
            <ValueSource h={h} />
          </p>
          {h.link_pattern && <p className="mt-0.5 text-[11px] text-subtle">{linkRuleText(h.link_pattern, h.link_exact)}</p>}
          {h.notes && <p className="mt-1 text-[12px] [overflow-wrap:anywhere] text-muted">{h.notes}</p>}
        </div>
      </div>
      <div className="flex shrink-0 flex-col gap-0.5 pl-15 sm:items-end sm:pl-0 sm:text-right">
        <p className={cn("tabular text-sm", h.value_aed === null ? "text-muted" : "font-medium text-ink")}>
          {h.value_aed === null ? noValueText(kind) : (own ?? formatTotal(h.value_aed))}
        </p>
        {own && aed && <p className="tabular text-[11px] text-subtle">{aed}</p>}
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
        {h.cost_aed !== null && <p className="tabular text-[11px] text-subtle">put in {formatTotal(h.cost_aed)}</p>}
        {kind === "metal" && h.change_24h_aed !== null && (
          <p className="text-[11px] text-subtle">
            <SignedTotal value={h.change_24h_aed} /> 24h
          </p>
        )}
        {(onEdit || onClose || onUpdateValue) && (
          <div className="mt-1 flex flex-wrap gap-x-4 sm:justify-end">
            {onUpdateValue && valueInput(kind) && (
              <Button size="sm" variant="link" className="text-[12px]" onClick={() => onUpdateValue(h)} aria-label={`Update the value of ${h.name}`}>
                Update value
              </Button>
            )}
            {onEdit && (
              <Button size="sm" variant="link" className="text-[12px]" onClick={() => onEdit(h)} aria-label={`Edit ${h.name}`}>
                Edit
              </Button>
            )}
            {onClose && (
              <Button size="sm" variant="link" className="text-[12px] text-muted" onClick={() => onClose(h)} aria-label={`Close ${h.name}`}>
                Close
              </Button>
            )}
          </div>
        )}
      </div>
    </li>
  );
}
