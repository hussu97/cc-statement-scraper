import { Link, useNavigate } from "@tanstack/react-router";
import { Briefcase } from "lucide-react";
import { wealthPortfolioRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useCashPosition } from "@/data/cash";
import { isNotFound, useAccountLedger } from "@/data/wealth";
import { useBrokerPortfolio } from "@/data/broker";
import { basisWords } from "@/lib/broker";
import { accountMonthStart, portfolioTab, shiftAccountMonth } from "@/lib/wealth";
import { monthEnd, monthStart, todayDubai } from "@/lib/dates";
import { Card } from "@/components/ui/display";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/primitives";
import { EmptyState, ErrorState, LoadingBlock } from "@/components/ui/states";
import { ACC_RE, AccountHeader, AccountNotFound, AccountStatement } from "@/components/wealth/account-page";
import { PortfolioCard } from "@/components/wealth/broker-portfolio";
import { PortfolioTab } from "@/components/wealth/broker-holdings";
import { PastNotesTab } from "@/components/wealth/broker-past";

/**
 * A synced broker account's portfolio (Wealth → Investments): the portfolio card with its value
 * chart, then tabs: Portfolio, Transactions (the account's statement) and Past.
 */
export function PortfolioPage() {
  const { accountCode } = wealthPortfolioRoute.useParams();
  if (!ACC_RE.test(accountCode)) return <AccountNotFound />;
  return <PortfolioView key={accountCode} accountCode={accountCode} />;
}

function NotABroker({ accountCode }: { accountCode: string }) {
  return (
    <Card>
      <EmptyState
        icon={<Briefcase />}
        title="No portfolio for this account"
        action={
          <Link to="/wealth/accounts/$accountCode" params={{ accountCode }} className="text-sm text-accent hover:underline">
            See the account
          </Link>
        }
      >
        It isn't a synced broker account.
      </EmptyState>
    </Card>
  );
}

function PortfolioView({ accountCode }: { accountCode: string }) {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const search = wealthPortfolioRoute.useSearch();
  const navigate = useNavigate({ from: "/wealth/investments/accounts/$accountCode" });
  const today = todayDubai();
  const start = accountMonthStart(search.month, today);
  const broker = useBrokerPortfolio(profileCode, accountCode);
  const portfolio = broker.data ?? null;
  const ledger = useAccountLedger(profileCode, accountCode, { from: start, to: monthEnd(start) });
  const cash = useCashPosition(profileCode);
  const position = cash.data?.accounts.find((a) => a.account_code === accountCode) ?? null;
  const setMonth = (by: number) => void navigate({ search: (s) => ({ ...s, month: shiftAccountMonth(start, by, today) }), replace: true, resetScroll: false });
  const setTab = (t: string) => void navigate({ search: (s) => ({ ...s, tab: portfolioTab(t) === "portfolio" ? undefined : portfolioTab(t) }), replace: true, resetScroll: false });

  if ((ledger.isError && isNotFound(ledger.error)) || (broker.isError && isNotFound(broker.error))) return <AccountNotFound />;

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <AccountHeader back={{ to: "/wealth/investments", label: "Investments" }} account={ledger.data?.account ?? position} />
      {broker.isLoading ? (
        <Card>
          <LoadingBlock className="h-72" />
        </Card>
      ) : broker.isError ? (
        <Card>
          <ErrorState title="Couldn't load the portfolio" error={broker.error} onRetry={() => void broker.refetch()} />
        </Card>
      ) : !portfolio ? (
        <NotABroker accountCode={accountCode} />
      ) : (
        <>
          <PortfolioCard portfolio={portfolio} />
          <Tabs value={portfolioTab(search.tab)} onValueChange={setTab}>
            <TabsList className="mb-4">
              <TabsTrigger value="portfolio">Portfolio</TabsTrigger>
              <TabsTrigger value="transactions">Transactions</TabsTrigger>
              <TabsTrigger value="past">
                {basisWords(portfolio.basis).past}
                {portfolio.closed.length > 0 ? ` (${portfolio.closed.length})` : ""}
              </TabsTrigger>
            </TabsList>
            <TabsContent value="portfolio">
              <PortfolioTab portfolio={portfolio} />
            </TabsContent>
            <TabsContent value="transactions" className="flex flex-col gap-6">
              <AccountStatement
                profileCode={profileCode}
                accountCode={accountCode}
                isOwner={isOwner}
                cash={cash}
                position={position}
                ledger={ledger}
                month={start}
                isCurrent={start === monthStart(today)}
                onMonth={setMonth}
              />
            </TabsContent>
            <TabsContent value="past">
              <PastNotesTab portfolio={portfolio} />
            </TabsContent>
          </Tabs>
        </>
      )}
    </div>
  );
}
