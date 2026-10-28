import { useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { ChevronLeft, Coins, History, ListPlus, Plus } from "lucide-react";
import { wealthHoldingRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useCashPosition } from "@/data/cash";
import { useHoldingDetail, useHoldingsValuation, type Holding, type HoldingDetail, type HoldingFlow, type MetalPrice } from "@/data/holdings";
import { formatPct, formatPurity, holdingPrice, quoteLabel, signTone } from "@/lib/holdings";
import {
  FLOW_KIND_LABEL,
  FLOW_SOURCE_LABEL,
  aedEquivalent,
  canRemoveFlow,
  depositValueNote,
  flowSign,
  formatOwnValue,
  formatUnitPrice,
  investmentAccount,
  isAccountBacked,
  kindOf,
  noValueText,
  rateAYear,
  valuationSourceLabel,
  valueInput,
  visibleValues,
} from "@/lib/investments";
import type { HoldingKind } from "@/lib/investments";
import { formatDate, formatRelative } from "@/lib/dates";
import { formatMoney, formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { HoldingAvatar } from "@/components/wealth/holding-image";
import { holdingFacts, ValueSource } from "@/components/wealth/holdings-list";
import { CloseHoldingDialog, HoldingDialog } from "@/components/wealth/holding-dialogs";
import { BackingAccountCard, TrackAccountDialog, type TrackTarget } from "@/components/wealth/account-investment";
import { AddFlowDialog, RemoveFlowDialog, UpdateValueDialog } from "@/components/wealth/holding-value-dialogs";
import { ReturnsCard } from "@/components/wealth/returns";
import { TONE_TEXT } from "@/components/wealth/investments";
import { NoteView } from "@/components/notes/note-view";
import { useNotesSummary } from "@/data/notes";

const HLD_RE = /^hld_[0-9a-z]{26}$/;

/** One holding (Wealth → Investments): value, cost, income and gain, returns, flows and value history. */
export function HoldingPage() {
  const { holdingCode } = wealthHoldingRoute.useParams();
  if (!HLD_RE.test(holdingCode)) return <HoldingNotFound />;
  return <HoldingOrNote key={holdingCode} holdingCode={holdingCode} />;
}

/** A structured note has its own page (live or ended); every other holding the holding page. */
function HoldingOrNote({ holdingCode }: { holdingCode: string }) {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const notes = useNotesSummary(profileCode);
  if (notes.isLoading) {
    return (
      <Card>
        <LoadingRows rows={3} />
      </Card>
    );
  }
  if (notes.data?.some((n) => n.holding_code === holdingCode)) return <NoteView profileCode={profileCode} holdingCode={holdingCode} isOwner={isOwner} />;
  return <HoldingView holdingCode={holdingCode} />;
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
  const navigate = useNavigate();
  const q = useHoldingsValuation(profileCode);
  const detail = useHoldingDetail(profileCode, holdingCode);
  // A savings account's bank account: holdings_valuation doesn't name it, cash_position does.
  const cash = useCashPosition(profileCode);
  const h = q.data?.holdings.find((x) => x.holding_code === holdingCode) ?? null;
  const accountBacked = isAccountBacked(h?.kind);
  const backing = investmentAccount(cash.data?.accounts, holdingCode);
  const [editing, setEditing] = useState(false);
  const [updating, setUpdating] = useState(false);
  const [adding, setAdding] = useState(false);
  const [removing, setRemoving] = useState<HoldingFlow | null>(null);
  const [rating, setRating] = useState<TrackTarget | null>(null);
  const [closing, setClosing] = useState<Holding | null>(null);
  const [leaving, setLeaving] = useState(false);

  if (q.data && !h) {
    // Just closed here: the page is about to leave (CloseHoldingDialog's onClosed).
    return closing || leaving ? (
      <Card>
        <LoadingRows rows={3} />
      </Card>
    ) : (
      <HoldingNotFound />
    );
  }

  // A savings account is its bank account's balance: no value, flow, link or form edits, only
  // its stated rate and leaving Investments.
  const summaryActions: SummaryActions = !isOwner || !h
    ? {}
    : accountBacked
      ? {
          onRate: backing ? () => setRating({ accountCode: backing.account_code, label: h.name, ratePct: h.rate_pct, shown: true }) : undefined,
          onRemove: () => setClosing(h),
        }
      : { onUpdate: valueInput(h.kind) ? () => setUpdating(true) : undefined, onEdit: () => setEditing(true) };

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
        <SummaryCard h={h} actions={summaryActions} />
      )}

      <ReturnsCard profileCode={profileCode} holdingCode={holdingCode} />

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)]">
        <FlowsCard
          detail={detail}
          currency={h?.currency ?? "AED"}
          accountBacked={accountBacked}
          onAdd={isOwner && h && !accountBacked ? () => setAdding(true) : undefined}
          onRemove={isOwner ? setRemoving : undefined}
        />
        {h && kindOf(h) === "metal" ? (
          <PriceCard h={h} price={holdingPrice(h, q.data?.prices)} />
        ) : accountBacked ? (
          <BackingAccountCard cash={cash} account={backing} />
        ) : (
          <ValuesCard h={h} detail={detail} onUpdate={isOwner && h && valueInput(h.kind) ? () => setUpdating(true) : undefined} />
        )}
      </div>

      {isOwner && h && (
        <>
          <HoldingDialog profileCode={profileCode} open={editing} holding={h} onClose={() => setEditing(false)} />
          <UpdateValueDialog profileCode={profileCode} holding={updating ? h : null} onClose={() => setUpdating(false)} />
          <AddFlowDialog profileCode={profileCode} holding={h} open={adding} onClose={() => setAdding(false)} />
          <RemoveFlowDialog profileCode={profileCode} flow={removing} currency={h.currency ?? "AED"} onClose={() => setRemoving(null)} />
          <TrackAccountDialog profileCode={profileCode} target={rating} onClose={() => setRating(null)} />
          <CloseHoldingDialog
            profileCode={profileCode}
            holding={closing}
            onClose={() => setClosing(null)}
            onClosed={() => {
              setLeaving(true);
              void (backing
                ? navigate({ to: "/wealth/accounts/$accountCode", params: { accountCode: backing.account_code } })
                : navigate({ to: "/wealth/investments" }));
            }}
          />
        </>
      )}
    </div>
  );
}

interface SummaryActions {
  onUpdate?: () => void;
  onEdit?: () => void;
  /** A savings account: change its stated rate. */
  onRate?: () => void;
  /** A savings account: stop showing it under Investments. */
  onRemove?: () => void;
}

function SummaryCard({ h, actions: { onUpdate, onEdit, onRate, onRemove } }: { h: Holding; actions: SummaryActions }) {
  const kind = kindOf(h);
  const accountBacked = isAccountBacked(kind);
  const foreign = !!h.currency && h.currency !== "AED";
  const own = foreign ? formatOwnValue(h.value, h.currency) : null;
  const gainPct = formatPct(h.gain_pct, { signed: true });
  const rate = accountBacked ? rateAYear(h.rate_pct) : null;
  return (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-4 px-5 pt-5">
        <div>
          <p className="text-[12px] text-subtle">{h.is_estimate ? "Value (estimated)" : accountBacked ? "Value: the account's balance" : "Value"}</p>
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
        {(onUpdate || onEdit || onRate || onRemove) && (
          <div className="flex flex-wrap gap-2">
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
            {onRate && (
              <Button size="sm" onClick={onRate}>
                {h.rate_pct ? "Change rate" : "Add rate"}
              </Button>
            )}
            {onRemove && (
              <Button size="sm" variant="ghost" onClick={onRemove}>
                Remove from Investments
              </Button>
            )}
          </div>
        )}
      </div>
      <dl className="grid grid-cols-2 gap-x-6 gap-y-3 px-5 pt-4 pb-5 text-sm sm:grid-cols-4">
        <div>
          <dt className="text-[12px] text-subtle">{accountBacked ? "Moved in, net" : "Put in"}</dt>
          <dd className="tabular mt-0.5 text-ink">{h.cost_aed === null ? <span className="text-muted">Nothing recorded</span> : formatTotal(h.cost_aed)}</dd>
        </div>
        <div>
          <dt className="text-[12px] text-subtle">{accountBacked ? "Interest earned" : "Income paid out"}</dt>
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
        {rate && (
          <div>
            <dt className="text-[12px] text-subtle">Interest rate</dt>
            <dd className="tabular mt-0.5 text-ink">{rate}</dd>
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
  accountBacked,
  onAdd,
  onRemove,
}: {
  detail: ReturnType<typeof useHoldingDetail>;
  currency: string;
  /** A savings account: its flows are its account's transfers and interest. */
  accountBacked: boolean;
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
          {accountBacked
            ? "Transfers into and out of the account, and the interest it pays, appear here as its statements and alerts arrive."
            : "Link the payments that paid into it from their transaction, set a link rule on the holding, or add an amount paid from elsewhere."}
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

/** The Dubai retail rate per gram that values a metal holding (its own metal and purity), with its 24-hour change and age. */
function PriceCard({ h, price }: { h: Holding; price: MetalPrice | null }) {
  const change = price ? formatPct(price.change_24h_pct, { signed: true }) : null;
  return (
    <Card>
      <CardHeader eyebrow="Dubai retail, per gram" title={quoteLabel(h.quote)} />
      {price ? (
        <div className="px-5 pb-5">
          <p className="tabular text-2xl font-medium text-ink">{formatMoney(price.aed_per_gram)}</p>
          <p className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-subtle">
            {change && <span className={cn("tabular", TONE_TEXT[signTone(price.change_24h_pct)])}>{change} in 24 hours</span>}
            <span>as of {formatRelative(price.as_of)}</span>
            {price.is_stale && <Badge tone="warn">Stale</Badge>}
          </p>
          <p className="mt-3 text-[12px] text-muted">The holding is valued at this rate, refreshed every 6 hours.</p>
        </div>
      ) : (
        <EmptyState icon={<Coins />} title="No price yet">
          Bank Ledger fetches gold and silver prices every 6 hours. The holding is valued from the first fetch.
        </EmptyState>
      )}
      <p className="border-t border-border px-5 py-3 text-[11px] text-subtle">Gold: Dubai Jewellery Group rates. Silver: Dubai retail rate.</p>
    </Card>
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
      {kind === "deposit" && h ? (
        <>
          <p className="px-5 pb-5 text-[13px] text-muted">{depositValueNote(h, (detail.data?.valuations.length ?? 0) > 0)}</p>
          {detail.data && detail.data.valuations.length > 0 && <ValueList detail={detail.data} currency={h.currency ?? "AED"} kind={kind} />}
        </>
      ) : detail.isLoading || !h ? (
        <LoadingRows rows={3} />
      ) : detail.isError || !detail.data ? (
        <ErrorState error={detail.error} onRetry={() => void detail.refetch()} />
      ) : (
        <ValueList detail={detail.data} currency={h.currency ?? "AED"} kind={kind} />
      )}
    </Card>
  );
}

function ValueList({ detail, currency, kind }: { detail: HoldingDetail; currency: string; kind: HoldingKind | null }) {
  const [showAll, setShowAll] = useState(false);
  const isPrice = kind === "security";
  if (detail.valuations.length === 0) {
    return (
      <EmptyState icon={<History />} title="No values recorded yet">
        {isPrice ? "Enter a unit price: the holding is valued at your units times it." : "Enter the value from your latest statement: it counts in your net worth from then."}
      </EmptyState>
    );
  }
  const { shown, hidden } = visibleValues(detail.valuations, showAll);
  return (
    <ul className="divide-y divide-border border-t border-border">
      {shown.map((v) => (
        <li key={v.valuation_code} className="flex items-baseline justify-between gap-3 px-5 py-2.5 text-sm">
          <span className="text-ink-2">
            {formatDate(v.as_of)}
            {valuationSourceLabel(kind, v.source) && <span className="ml-2 text-[11px] text-subtle">{valuationSourceLabel(kind, v.source)}</span>}
          </span>
          <span className="tabular text-ink">
            {isPrice ? `${formatUnitPrice(v.unit_price, currency)} a unit` : formatTotal(v.value, { currency })}
          </span>
        </li>
      ))}
      {hidden > 0 && (
        <li className="px-5 py-2">
          <Button variant="ghost" size="sm" onClick={() => setShowAll(true)}>
            Show all {detail.valuations.length} values
          </Button>
        </li>
      )}
    </ul>
  );
}
