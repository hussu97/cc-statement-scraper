import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronLeft, Coins, History, ListPlus, Plus } from "lucide-react";
import { wealthHoldingRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useHoldingDetail, useHoldingsValuation, type Holding, type HoldingDetail, type HoldingFlow } from "@/data/holdings";
import { formatPct, formatPurity, signTone } from "@/lib/holdings";
import { FLOW_KIND_LABEL, FLOW_SOURCE_LABEL, aedEquivalent, canRemoveFlow, flowSign, formatOwnValue, formatRate, formatUnitPrice, kindOf, noValueText, valueInput } from "@/lib/investments";
import { formatDate } from "@/lib/dates";
import { formatMoney, formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card, CardHeader, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { HoldingAvatar } from "@/components/wealth/holding-image";
import { holdingFacts, ValueSource } from "@/components/wealth/holdings-list";
import { HoldingDialog } from "@/components/wealth/holding-dialogs";
import { AddFlowDialog, RemoveFlowDialog, UpdateValueDialog } from "@/components/wealth/holding-value-dialogs";
import { ReturnsCard } from "@/components/wealth/returns";
import { TONE_TEXT } from "@/components/wealth/investments";

const HLD_RE = /^hld_[0-9a-z]{26}$/;

/** One holding (Wealth → Investments): value, cost, income and gain, returns, flows and value history. */
export function HoldingPage() {
  const { holdingCode } = wealthHoldingRoute.useParams();
  if (!HLD_RE.test(holdingCode)) return <HoldingNotFound />;
  return <HoldingView key={holdingCode} holdingCode={holdingCode} />;
}

function HoldingNotFound() {
  return (
    <Card>
      <EmptyState
        icon={<Coins />}
        title="Holding not found"
        action={
          <Link to="/wealth/investments" className="text-sm text-accent hover:underline">
            See your investments
          </Link>
        }
      >
        It isn't in this ledger, or it was closed.
      </EmptyState>
    </Card>
  );
}

function HoldingView({ holdingCode }: { holdingCode: string }) {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const q = useHoldingsValuation(profileCode);
  const detail = useHoldingDetail(profileCode, holdingCode);
  const h = q.data?.holdings.find((x) => x.holding_code === holdingCode) ?? null;
  const [editing, setEditing] = useState(false);
  const [updating, setUpdating] = useState(false);
  const [adding, setAdding] = useState(false);
  const [removing, setRemoving] = useState<HoldingFlow | null>(null);

  if (q.data && !h) return <HoldingNotFound />;

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <div>
        <Link to="/wealth/investments" className="tap -ml-1 inline-flex items-center gap-1 text-[13px] text-muted hover:text-accent">
          <ChevronLeft className="size-3.5" /> Investments
        </Link>
        <header className="mt-3 flex items-center gap-3">
          {h ? <HoldingAvatar h={h} /> : <Skeleton className="size-12 rounded-md" />}
          <div className="min-w-0">
            <h1 className="truncate font-display text-[26px] leading-tight text-ink md:text-[30px]">{h ? h.name : <Skeleton className="h-8 w-48" />}</h1>
            {h && <p className="text-[13px] text-muted">{holdingFacts(h)}</p>}
          </div>
        </header>
      </div>

      {q.isLoading ? (
        <Card>
          <LoadingRows rows={2} />
        </Card>
      ) : q.isError || !h ? (
        <Card>
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        </Card>
      ) : (
        <SummaryCard h={h} onUpdate={isOwner && valueInput(h.kind) ? () => setUpdating(true) : undefined} onEdit={isOwner ? () => setEditing(true) : undefined} />
      )}

      <ReturnsCard profileCode={profileCode} holdingCode={holdingCode} />

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)]">
        <FlowsCard
          detail={detail}
          currency={h?.currency ?? "AED"}
          onAdd={isOwner && h ? () => setAdding(true) : undefined}
          onRemove={isOwner ? setRemoving : undefined}
        />
        <ValuesCard h={h} detail={detail} onUpdate={isOwner && h && valueInput(h.kind) ? () => setUpdating(true) : undefined} />
      </div>

      {isOwner && h && (
        <>
          <HoldingDialog profileCode={profileCode} open={editing} holding={h} onClose={() => setEditing(false)} />
          <UpdateValueDialog profileCode={profileCode} holding={updating ? h : null} onClose={() => setUpdating(false)} />
          <AddFlowDialog profileCode={profileCode} holding={h} open={adding} onClose={() => setAdding(false)} />
          <RemoveFlowDialog profileCode={profileCode} flow={removing} currency={h.currency ?? "AED"} onClose={() => setRemoving(null)} />
        </>
      )}
    </div>
  );
}

function SummaryCard({ h, onUpdate, onEdit }: { h: Holding; onUpdate?: () => void; onEdit?: () => void }) {
  const kind = kindOf(h);
  const foreign = !!h.currency && h.currency !== "AED";
  const own = foreign ? formatOwnValue(h.value, h.currency) : null;
  const gainPct = formatPct(h.gain_pct, { signed: true });
  return (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-4 px-5 pt-5">
        <div>
          <p className="text-[12px] text-subtle">{h.is_estimate ? "Value (estimated)" : "Value"}</p>
          {h.value_aed === null ? (
            <p className="mt-1 text-lg text-muted">{noValueText(kind)}</p>
          ) : (
            <>
              <p className="tabular mt-0.5 text-[32px] leading-tight font-medium text-ink">{own ?? formatTotal(h.value_aed)}</p>
              {own && <p className="tabular text-[12px] text-subtle">{aedEquivalent(h.value_aed, h.currency)}</p>}
            </>
          )}
          <p className="mt-1">
            <ValueSource h={h} />
          </p>
        </div>
        {(onUpdate || onEdit) && (
          <div className="flex gap-2">
            {onUpdate && (
              <Button size="sm" variant="primary" onClick={onUpdate}>
                Update value
              </Button>
            )}
            {onEdit && (
              <Button size="sm" onClick={onEdit}>
                Edit
              </Button>
            )}
          </div>
        )}
      </div>
      <dl className="grid grid-cols-2 gap-x-6 gap-y-3 px-5 pt-4 pb-5 text-sm sm:grid-cols-4">
        <div>
          <dt className="text-[12px] text-subtle">Put in</dt>
          <dd className="tabular mt-0.5 text-ink">{h.cost_aed === null ? <span className="text-muted">Nothing recorded</span> : formatTotal(h.cost_aed)}</dd>
        </div>
        <div>
          <dt className="text-[12px] text-subtle">Income paid out</dt>
          <dd className="tabular mt-0.5 text-ink">{formatTotal(h.income_aed ?? "0")}</dd>
        </div>
        <div>
          <dt className="text-[12px] text-subtle">Gain</dt>
          <dd className="mt-0.5">
            {h.gain_aed === null ? (
              <span className="text-muted">{h.cost_aed === null ? "Add what you put in" : "Not known yet"}</span>
            ) : (
              <span className={cn("tabular", TONE_TEXT[signTone(h.gain_aed)])}>
                <span className="whitespace-nowrap">{formatTotal(h.gain_aed, { signed: true })}</span>
                {gainPct && <span className="ml-1 text-[0.85em] whitespace-nowrap">({gainPct})</span>}
              </span>
            )}
          </dd>
        </div>
        {kind === "deposit" && h.principal && (
          <div>
            <dt className="text-[12px] text-subtle">Principal</dt>
            <dd className="tabular mt-0.5 text-ink">{formatTotal(h.principal, { currency: h.currency ?? "AED" })}</dd>
          </div>
        )}
        {kind === "metal" && h.metal === "silver" && h.purity && (
          <div>
            <dt className="text-[12px] text-subtle">Purity</dt>
            <dd className="tabular mt-0.5 text-ink">{formatPurity(h.purity)}</dd>
          </div>
        )}
      </dl>
      {h.link_pattern && (
        <p className="border-t border-border px-5 py-3 text-[12px] text-muted">
          Payments whose description {h.link_exact ? "is exactly" : "contains"} “<span className="text-ink-2">{h.link_pattern}</span>” are linked here automatically and count as
          saving, not spending.
        </p>
      )}
    </Card>
  );
}

function FlowsCard({
  detail,
  currency,
  onAdd,
  onRemove,
}: {
  detail: ReturnType<typeof useHoldingDetail>;
  currency: string;
  onAdd?: () => void;
  onRemove?: (f: HoldingFlow) => void;
}) {
  return (
    <Card>
      <CardHeader
        eyebrow="Money in and out"
        title="Flows"
        action={
          onAdd && (
            <Button size="sm" icon={<Plus className="size-3.5" />} onClick={onAdd}>
              Add
            </Button>
          )
        }
      />
      {detail.isLoading ? (
        <LoadingRows rows={4} />
      ) : detail.isError || !detail.data ? (
        <ErrorState error={detail.error} onRetry={() => void detail.refetch()} />
      ) : detail.data.flows.length === 0 ? (
        <EmptyState icon={<ListPlus />} title="No money in or out yet">
          Link the payments that paid into it from their transaction, set a link rule on the holding, or add an amount paid from elsewhere.
        </EmptyState>
      ) : (
        <ul className="divide-y divide-border border-t border-border">
          {detail.data.flows.map((f) => (
            <FlowRow key={f.flow_code} f={f} currency={currency} onRemove={onRemove && canRemoveFlow(f.source) ? () => onRemove(f) : undefined} />
          ))}
        </ul>
      )}
    </Card>
  );
}

function FlowRow({ f, currency, onRemove }: { f: HoldingFlow; currency: string; onRemove?: () => void }) {
  const sign = flowSign(f.kind);
  return (
    <li className="flex items-start gap-3 px-5 py-3">
      <div className="min-w-0 flex-1">
        <p className="text-sm text-ink">
          {FLOW_KIND_LABEL[f.kind] ?? f.kind} <span className="text-[12px] text-subtle">· {formatDate(f.flow_date)}</span>
        </p>
        {f.txn_code ? (
          <Link to="/activity" search={{ txn: f.txn_code }} className="mt-0.5 flex min-w-0 items-center gap-1.5 text-[12px] text-ink-2 hover:text-accent">
            {f.txn_bank_code && <BankLogo bankCode={f.txn_bank_code} size="xs" />}
            <span className="truncate">{f.txn_description ?? "Linked payment"}</span>
          </Link>
        ) : (
          f.notes && <p className="mt-0.5 text-[12px] [overflow-wrap:anywhere] text-ink-2">{f.notes}</p>
        )}
        <p className="mt-0.5 text-[11px] text-subtle">{FLOW_SOURCE_LABEL[f.source] ?? f.source}</p>
      </div>
      <div className="flex shrink-0 flex-col items-end gap-0.5 text-right">
        <span className={cn("tabular text-sm", f.kind === "income" ? "text-positive" : "text-ink")}>
          {sign}
          {formatMoney(f.amount, { currency })}
        </span>
        {currency !== "AED" && <span className="tabular text-[11px] text-subtle">{formatMoney(f.amount_aed)}</span>}
        {onRemove && (
          <Button size="sm" variant="link" className="text-[12px] text-muted" onClick={onRemove} aria-label={f.txn_code ? "Unlink this payment" : "Remove this entry"}>
            {f.txn_code ? "Unlink" : "Remove"}
          </Button>
        )}
      </div>
    </li>
  );
}

function ValuesCard({ h, detail, onUpdate }: { h: Holding | null; detail: ReturnType<typeof useHoldingDetail>; onUpdate?: () => void }) {
  const kind = h ? kindOf(h) : null;
  return (
    <Card>
      <CardHeader
        eyebrow="Value history"
        title={kind === "security" ? "Unit prices" : "Values"}
        action={
          onUpdate && (
            <Button size="sm" onClick={onUpdate}>
              Update value
            </Button>
          )
        }
      />
      {kind === "metal" ? (
        <p className="px-5 pb-5 text-[13px] text-muted">Valued at Dubai's retail rate for its metal and karat, refreshed every 6 hours. The price chart is on the Investments page.</p>
      ) : kind === "deposit" ? (
        <p className="px-5 pb-5 text-[13px] text-muted">
          An estimate: the principal plus simple profit at {h?.rate_pct ? formatRate(h.rate_pct) : "its rate"} a year, accrued day by day to maturity
          {h?.maturity_on ? ` on ${formatDate(h.maturity_on.slice(0, 10))}` : ""}.
        </p>
      ) : detail.isLoading || !h ? (
        <LoadingRows rows={3} />
      ) : detail.isError || !detail.data ? (
        <ErrorState error={detail.error} onRetry={() => void detail.refetch()} />
      ) : (
        <ValueList detail={detail.data} currency={h.currency ?? "AED"} isPrice={kind === "security"} />
      )}
    </Card>
  );
}

function ValueList({ detail, currency, isPrice }: { detail: HoldingDetail; currency: string; isPrice: boolean }) {
  if (detail.valuations.length === 0) {
    return (
      <EmptyState icon={<History />} title="No values recorded yet">
        {isPrice ? "Enter a unit price: the holding is valued at your units times it." : "Enter the value from your latest statement: it counts in your net worth from then."}
      </EmptyState>
    );
  }
  return (
    <ul className="divide-y divide-border border-t border-border">
      {detail.valuations.map((v) => (
        <li key={v.valuation_code} className="flex items-baseline justify-between gap-3 px-5 py-2.5 text-sm">
          <span className="text-ink-2">{formatDate(v.as_of)}</span>
          <span className="tabular text-ink">
            {isPrice ? `${formatUnitPrice(v.unit_price, currency)} a unit` : formatTotal(v.value, { currency })}
          </span>
        </li>
      ))}
    </ul>
  );
}
