import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronLeft, Landmark } from "lucide-react";
import type { CashAccount, useCashPosition } from "@/data/cash";
import type { useAccountLedger } from "@/data/wealth";
import { bankAccountLabel } from "@/lib/cash-flow";
import { accountKindLabel } from "@/lib/wealth";
import type { ISODate } from "@/lib/dates";
import { Card, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { UpdateBalanceDialog } from "@/components/cash/bank-account-dialogs";
import { AccountEntryDialog } from "@/components/notes/account-entry-dialog";
import { BalanceCard, StatementCard } from "./account-statement";

// What a bank account's page and a broker account's portfolio page share: the header, the
// not-found state, and the balance with the month as a statement.

export const ACC_RE = /^acc_[0-9a-z]{26}$/;

export function AccountNotFound() {
  return (
    <Card>
      <EmptyState
        icon={<Landmark />}
        title="Account not found"
        action={
          <Link to="/wealth/accounts" className="text-sm text-accent hover:underline">
            See your accounts
          </Link>
        }
      >
        It isn't a bank account in this ledger, or it was removed.
      </EmptyState>
    </Card>
  );
}

type AccountLike = { bank_code: string; kind?: string | null; account_ref?: string | null; currency: string; nickname?: string | null };

/** The back link, the bank's logo, the account's name and its kind · bank ··· ref · currency. */
export function AccountHeader({ back, account }: { back: { to: "/wealth/accounts" | "/wealth/investments"; label: string }; account: AccountLike | null }) {
  return (
    <div>
      <Link to={back.to} className="tap -ml-1 inline-flex items-center gap-1 text-[13px] text-muted hover:text-accent">
        <ChevronLeft className="size-3.5" /> {back.label}
      </Link>
      <header className="mt-3 flex items-center gap-3">
        {account ? <BankLogo bankCode={account.bank_code} size="lg" /> : <Skeleton className="size-10 rounded-md" />}
        <div className="min-w-0">
          <h1 className="truncate font-display text-[26px] leading-tight text-ink md:text-[30px]">
            {account ? bankAccountLabel(account) : <Skeleton className="h-8 w-48" />}
          </h1>
          {account && (
            <p className="text-[13px] text-muted">
              {accountKindLabel(account.kind)} · {account.bank_code}
              {account.account_ref ? ` ··· ${account.account_ref}` : ""}
              {account.currency.toUpperCase() !== "AED" ? ` · ${account.currency.toUpperCase()}` : ""}
            </p>
          )}
        </div>
      </header>
    </div>
  );
}

/**
 * What any bank account shows: its balance (with Update for the owner), "Add a deposit or
 * withdrawal", and the month as a statement, with the dialogs those open.
 */
export function AccountStatement({
  profileCode,
  accountCode,
  isOwner,
  cash,
  position,
  ledger,
  month,
  isCurrent,
  onMonth,
}: {
  profileCode: string;
  accountCode: string;
  isOwner: boolean;
  cash: ReturnType<typeof useCashPosition>;
  position: CashAccount | null;
  ledger: ReturnType<typeof useAccountLedger>;
  month: ISODate;
  isCurrent: boolean;
  onMonth: (by: number) => void;
}) {
  const [updating, setUpdating] = useState<CashAccount | null>(null);
  const [entering, setEntering] = useState<CashAccount | null>(null);
  return (
    <>
      <BalanceCard
        profileCode={profileCode}
        accountCode={accountCode}
        position={position}
        loading={cash.isLoading}
        error={cash.isError ? cash.error : null}
        retry={() => void cash.refetch()}
        onUpdate={isOwner && position ? () => setUpdating(position) : undefined}
      />
      {isOwner && position && (
        <div className="-mt-3 flex justify-end">
          <Button size="sm" variant="link" className="text-[13px]" onClick={() => setEntering(position)}>
            Add a deposit or withdrawal
          </Button>
        </div>
      )}
      <StatementCard profileCode={profileCode} ledger={ledger} month={month} isCurrent={isCurrent} isOwner={isOwner} onMonth={onMonth} />
      {isOwner && <UpdateBalanceDialog profileCode={profileCode} account={updating} onClose={() => setUpdating(null)} />}
      {isOwner && <AccountEntryDialog profileCode={profileCode} account={entering} onClose={() => setEntering(null)} />}
    </>
  );
}
