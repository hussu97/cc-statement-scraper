import { useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { Landmark, Plus } from "lucide-react";
import { useCashPosition, type CashAccount } from "@/data/cash";
import { balanceSourceLabel, bankAccountLabel, cashCaveat } from "@/lib/cash-flow";
import { formatMoney, formatTotal } from "@/lib/money";
import { formatRelative } from "@/lib/dates";
import { BankLogo } from "@/components/bank-logo";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { AddBankAccountDialog, UpdateBalanceDialog } from "./bank-account-dialogs";

/**
 * The ledger's bank accounts with their balances and the AED total (public.cash_position). Each
 * row opens the account's page (Wealth mode). `headerLink` sits beside Add in the header.
 */
export function BankAccountsCard({ profileCode, isOwner, eyebrow = "Cash", headerLink }: { profileCode: string; isOwner: boolean; eyebrow?: string; headerLink?: ReactNode }) {
  const q = useCashPosition(profileCode);
  const [adding, setAdding] = useState(false);
  const [updating, setUpdating] = useState<CashAccount | null>(null);
  const caveat = q.data ? cashCaveat(q.data) : null;

  return (
    <Card>
      <CardHeader
        eyebrow={eyebrow}
        title="Bank accounts"
        action={
          (isOwner || headerLink) && (
            <div className="flex items-center gap-3">
              {headerLink}
              {isOwner && (
                <Button size="sm" icon={<Plus className="size-3.5" />} onClick={() => setAdding(true)}>
                  <span className="sm:hidden">Add</span>
                  <span className="hidden sm:inline">Add bank account</span>
                </Button>
              )}
            </div>
          )
        }
      />
      {q.isLoading ? (
        <LoadingRows rows={2} />
      ) : q.isError || !q.data ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : q.data.accounts.length === 0 ? (
        <EmptyState
          icon={<Landmark />}
          title="No bank accounts yet"
          action={
            <Link to="/settings" search={{ tab: "sms" }} className="text-sm text-accent hover:underline">
              Set up the account automation
            </Link>
          }
        >
          {isOwner ? "Add one, or set up the Account automation so its alerts add balances and transfers." : "The ledger's owner can add one, or set up the Account automation."}
        </EmptyState>
      ) : (
        <>
          <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1 border-b border-border px-5 pb-4">
            <span className="text-[12px] text-subtle">Total</span>
            <span className="tabular text-2xl font-medium text-ink">{formatTotal(q.data.total_aed)}</span>
            {caveat && <span className="text-[12px] text-warn">{caveat}</span>}
          </div>
          <ul className="divide-y divide-border">
            {q.data.accounts.map((a) => (
              <AccountRow key={a.account_code} account={a} onUpdate={isOwner ? () => setUpdating(a) : undefined} />
            ))}
          </ul>
        </>
      )}
      {isOwner && <AddBankAccountDialog profileCode={profileCode} open={adding} onOpenChange={setAdding} />}
      {isOwner && <UpdateBalanceDialog profileCode={profileCode} account={updating} onClose={() => setUpdating(null)} />}
    </Card>
  );
}

function AccountRow({ account: a, onUpdate }: { account: CashAccount; onUpdate?: () => void }) {
  const source = balanceSourceLabel(a.anchor_source);
  const foreign = a.currency.toUpperCase() !== "AED";
  return (
    <li className="flex items-start gap-3 px-5 py-3.5">
      <BankLogo bankCode={a.bank_code} />
      <div className="min-w-0 flex-1">
        <Link
          to="/wealth/accounts/$accountCode"
          params={{ accountCode: a.account_code }}
          className="block truncate text-sm font-medium text-ink hover:text-accent hover:underline"
        >
          {bankAccountLabel(a)}
        </Link>
        <p className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-subtle">
          <span className="whitespace-nowrap">{a.bank_code}{a.nickname && a.account_ref ? ` ··· ${a.account_ref}` : ""}</span>
          {a.balance !== null && a.as_of && <span className="whitespace-nowrap">as of {formatRelative(a.as_of)}{source ? `, ${source}` : ""}</span>}
          {a.is_stale && <Badge tone="warn">Over a week old</Badge>}
        </p>
      </div>
      <div className="flex shrink-0 flex-col items-end gap-0.5 text-right">
        {a.balance === null ? (
          <p className="text-sm text-muted">No balance yet</p>
        ) : (
          <>
            <p className="tabular text-sm font-medium text-ink">{formatMoney(a.balance, { currency: a.currency })}</p>
            {foreign && <p className="tabular text-[11px] text-subtle">{a.balance_aed ? `≈ ${formatTotal(a.balance_aed)}` : "No AED rate yet"}</p>}
            {a.unpriced_count > 0 && <p className="text-[11px] text-subtle">Excludes {a.unpriced_count} without an AED amount</p>}
          </>
        )}
        {onUpdate && (
          <Button size="sm" variant="link" className="text-[12px]" onClick={onUpdate} aria-label={`Update balance of ${bankAccountLabel(a)}`}>
            Update balance
          </Button>
        )}
      </div>
    </li>
  );
}
