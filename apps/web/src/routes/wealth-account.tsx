import { useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { ChevronLeft, Landmark } from "lucide-react";
import { wealthAccountRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useCashPosition, type CashAccount } from "@/data/cash";
import { isNotFound, useAccountLedger } from "@/data/wealth";
import { useBrokerPortfolio } from "@/data/broker";
import { bankAccountLabel } from "@/lib/cash-flow";
import { accountKindLabel, accountMonthStart, accountTab, shiftAccountMonth } from "@/lib/wealth";
import { monthEnd, monthStart, todayDubai } from "@/lib/dates";
import { Card, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/primitives";
import { EmptyState, ErrorState, LoadingBlock } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { UpdateBalanceDialog } from "@/components/cash/bank-account-dialogs";
import { AccountEntryDialog } from "@/components/notes/account-entry-dialog";
import { BalanceCard, StatementCard } from "@/components/wealth/account-statement";
import { PortfolioCard } from "@/components/wealth/broker-portfolio";
import { PortfolioTab } from "@/components/wealth/broker-holdings";
import { PastNotesTab } from "@/components/wealth/broker-past";

const ACC_RE = /^acc_[0-9a-z]{26}$/;

/**
 * One bank account (Wealth mode): its balance, balance over time, and the month as a statement. A
 * synced broker account (Swissquote) leads with its portfolio, then tabs: Portfolio, Transactions
 * (the statement) and Past notes.
 */
export function AccountPage() {
  const { accountCode } = wealthAccountRoute.useParams();
  if (!ACC_RE.test(accountCode)) return <AccountNotFound />;
  return <AccountView key={accountCode} accountCode={accountCode} />;
}

function AccountNotFound() {
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

function AccountView({ accountCode }: { accountCode: string }) {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const search = wealthAccountRoute.useSearch();
  const navigate = useNavigate({ from: "/wealth/accounts/$accountCode" });
  const today = todayDubai();
  const start = accountMonthStart(search.month, today);
  const isCurrent = start === monthStart(today);
  const ledger = useAccountLedger(profileCode, accountCode, { from: start, to: monthEnd(start) });
  const cash = useCashPosition(profileCode);
  const position = cash.data?.accounts.find((a) => a.account_code === accountCode) ?? null;
  // A broker account (Swissquote) has a synced portfolio; every other account returns null.
  const broker = useBrokerPortfolio(profileCode, accountCode);
  const portfolio = broker.data ?? null;
  const [updating, setUpdating] = useState<CashAccount | null>(null);
  const [entering, setEntering] = useState<CashAccount | null>(null);
  const setMonth = (by: number) => void navigate({ search: (s) => ({ ...s, month: shiftAccountMonth(start, by, today) }), replace: true, resetScroll: false });
  const setTab = (t: string) => void navigate({ search: (s) => ({ ...s, tab: accountTab(t) === "portfolio" ? undefined : accountTab(t) }), replace: true, resetScroll: false });

  if (ledger.isError && isNotFound(ledger.error)) return <AccountNotFound />;
  const account = ledger.data?.account ?? position;

  // What any bank account shows: its balance and the month as a statement.
  const statement = (
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
      <StatementCard profileCode={profileCode} ledger={ledger} month={start} isCurrent={isCurrent} isOwner={isOwner} onMonth={setMonth} />
    </>
  );

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <div>
        <Link to="/wealth/accounts" className="tap -ml-1 inline-flex items-center gap-1 text-[13px] text-muted hover:text-accent">
          <ChevronLeft className="size-3.5" /> Accounts
        </Link>
        <header className="mt-3 flex items-center gap-3">
          {account ? <BankLogo bankCode={account.bank_code} size="lg" /> : <Skeleton className="size-10 rounded-md" />}
          <div className="min-w-0">
            <h1 className="truncate font-display text-[26px] leading-tight text-ink md:text-[30px]">{account ? bankAccountLabel(account) : <Skeleton className="h-8 w-48" />}</h1>
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

      {broker.isError && !isNotFound(broker.error) && (
        <Card>
          <ErrorState title="Couldn't load the portfolio" error={broker.error} onRetry={() => void broker.refetch()} />
        </Card>
      )}
      {broker.isLoading ? (
        <Card>
          <LoadingBlock className="h-72" />
        </Card>
      ) : portfolio ? (
        <>
          <PortfolioCard portfolio={portfolio} />
          <Tabs value={accountTab(search.tab)} onValueChange={setTab}>
            <TabsList className="mb-4">
              <TabsTrigger value="portfolio">Portfolio</TabsTrigger>
              <TabsTrigger value="transactions">Transactions</TabsTrigger>
              <TabsTrigger value="past">Past notes{portfolio.closed.length > 0 ? ` (${portfolio.closed.length})` : ""}</TabsTrigger>
            </TabsList>
            <TabsContent value="portfolio">
              <PortfolioTab portfolio={portfolio} />
            </TabsContent>
            <TabsContent value="transactions" className="flex flex-col gap-6">
              {statement}
            </TabsContent>
            <TabsContent value="past">
              <PastNotesTab portfolio={portfolio} />
            </TabsContent>
          </Tabs>
        </>
      ) : (
        statement
      )}

      {isOwner && <UpdateBalanceDialog profileCode={profileCode} account={updating} onClose={() => setUpdating(null)} />}
      {isOwner && <AccountEntryDialog profileCode={profileCode} account={entering} onClose={() => setEntering(null)} />}
    </div>
  );
}
