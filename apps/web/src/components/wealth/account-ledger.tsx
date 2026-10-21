import { NotebookPen } from "lucide-react";
import type { LedgerRow } from "@/data/wealth";
import type { PickerCategory } from "@/components/ledger";
import { flowChip } from "@/lib/cash-flow";
import { formatLedgerAmount } from "@/lib/wealth";
import { formatDate, formatTime } from "@/lib/dates";
import { formatMoney, formatTotal } from "@/lib/money";
import { transferPeer } from "@/lib/transfers";
import { cn } from "@/lib/cn";
import { Badge } from "@/components/ui/display";
import { CategoryPicker, StatusBadge } from "@/components/ledger";
import { CardRef } from "@/components/bank-logo";
import { HoldingChip } from "./link-holding";

const GRID = "xl:grid-cols-[76px_minmax(0,1fr)_180px_120px_110px]";

/**
 * A bank account's month as a statement (account_ledger): date, description and flow, category
 * (editable, so a transfer can be filed as Support, Saving, Transfers or Salary), the signed
 * amount and the balance after it. Rows arrive newest first; the figures are the server's.
 */
export function AccountLedgerTable({
  rows,
  currency,
  categories,
  canEdit,
  onCategory,
  onOpen,
}: {
  rows: LedgerRow[];
  currency: string;
  categories: PickerCategory[];
  canEdit: boolean;
  onCategory: (row: LedgerRow, code: string | null, toMerchant: boolean) => void;
  onOpen: (row: LedgerRow) => void;
}) {
  return (
    <div role="table" aria-label="Account transactions">
      <div role="row" className={cn("hidden items-center gap-3 border-y border-border px-4 py-2 text-[11px] font-medium tracking-wide text-subtle uppercase xl:grid", GRID)}>
        <span role="columnheader">Date</span>
        <span role="columnheader">Description</span>
        <span role="columnheader">Category</span>
        <span role="columnheader" className="text-right">Amount</span>
        <span role="columnheader" className="text-right">Balance</span>
      </div>
      <div role="rowgroup" className="border-t border-border xl:border-t-0">
        {rows.map((r) => (
          <LedgerLine key={r.txn_code} r={r} currency={currency} categories={categories} canEdit={canEdit} onCategory={onCategory} onOpen={onOpen} />
        ))}
      </div>
    </div>
  );
}

function LedgerLine({
  r,
  currency,
  categories,
  canEdit,
  onCategory,
  onOpen,
}: {
  r: LedgerRow;
  currency: string;
  categories: PickerCategory[];
  canEdit: boolean;
  onCategory: (row: LedgerRow, code: string | null, toMerchant: boolean) => void;
  onOpen: (row: LedgerRow) => void;
}) {
  const chip = flowChip(r.flow);
  const peer = transferPeer(r);
  const voided = r.status === "void";
  return (
    <div
      role="row"
      className={cn(
        "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 gap-y-1 border-b border-border px-4 py-2.5 last:border-b-0 hover:bg-surface-2/50",
        GRID,
        voided && "text-muted",
      )}
    >
      <span role="cell" className="hidden text-[13px] text-ink-2 xl:block">
        <span className="block">{formatDate(r.txn_date, "short")}</span>
        {r.txn_at && <span className="tabular block text-[11px] text-subtle">{formatTime(r.txn_at)}</span>}
      </span>
      <span role="cell" className="min-w-0">
        <button type="button" data-txn-open={r.txn_code} onClick={() => onOpen(r)} className="block w-full min-w-0 text-left">
          <span className={cn("flex items-center gap-1.5 text-sm text-ink", voided && "line-through decoration-subtle")}>
            <span className="truncate">{r.merchant_name ?? r.description}</span>
            {r.notes && <NotebookPen className="size-3 shrink-0 text-subtle" aria-label="Has a note" />}
          </span>
          <span className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-muted">
            <span className="xl:hidden">{formatDate(r.txn_date, "short")}</span>
            {r.holding_name ? <HoldingChip name={r.holding_name} /> : chip && <Badge tone={chip.tone}>{chip.label}</Badge>}
            {peer && (
              <span className="inline-flex min-w-0 items-center gap-1">
                {peer.prefix} <CardRef bankCode={peer.bankCode} last4={peer.last4} />
              </span>
            )}
            <StatusBadge status={r.status} />
          </span>
        </button>
      </span>
      <span role="cell" className="order-last col-span-2 -ml-2 min-w-0 xl:order-none xl:col-span-1">
        <CategoryPicker
          categories={categories}
          value={r.category_code}
          label={r.category_name}
          colorToken={r.category_color}
          source={r.category_source}
          disabled={!canEdit}
          allowApplyToMerchant={!!r.merchant_code}
          onSelect={(code, toMerchant) => onCategory(r, code, toMerchant)}
        />
      </span>
      <span role="cell" className="flex flex-col items-end text-right">
        <Amount r={r} currency={currency} />
        {/* Phones: the balance after sits under the amount. */}
        <span className="tabular text-[11px] text-subtle xl:hidden">{r.balance_after !== null ? `bal ${formatTotal(r.balance_after, { currency })}` : null}</span>
      </span>
      <span role="cell" className="tabular hidden text-right text-[13px] text-ink-2 xl:block">
        {r.balance_after !== null ? formatTotal(r.balance_after, { currency }) : <span className="text-subtle">—</span>}
      </span>
    </div>
  );
}

function Amount({ r, currency }: { r: LedgerRow; currency: string }) {
  if (r.amount === null) {
    // Not in the account's currency and no rate: shown as charged, outside every figure.
    return (
      <>
        <span className="tabular text-sm whitespace-nowrap text-muted">{formatMoney(r.amount_original, { currency: r.currency_original ?? currency })}</span>
        <span className="text-[11px] text-warn">not in balance</span>
      </>
    );
  }
  return (
    <span className={cn("tabular text-sm whitespace-nowrap", r.direction === "credit" ? "text-positive" : "text-ink", r.status === "void" && "text-muted line-through")}>
      {formatLedgerAmount(r.amount, r.direction, currency)}
    </span>
  );
}
