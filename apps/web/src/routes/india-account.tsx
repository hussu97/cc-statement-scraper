import { Link, useNavigate } from "@tanstack/react-router";
import { indiaCoinRoute, indiaKiteRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useIndiaOverview } from "@/data/india";
import { useBrokerPortfolio } from "@/data/broker";
import { INDIA_TAB, indiaAccountFor, indiaAccountTab, type IndiaAccount, type IndiaAccountTab, type IndiaSegment } from "@/lib/india";
import { basisWords } from "@/lib/broker";
import { positionSort, positionSortParam, type PositionSort } from "@/lib/broker-detail";
import { Card, PageHeader } from "@/components/ui/display";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/primitives";
import { EmptyState, ErrorState, LoadingBlock } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { PortfolioCard } from "@/components/wealth/broker-portfolio";
import { AllocationCard, HighlightsCard, PositionsCard, SipsCard } from "@/components/india/india-portfolio";
import { PastNotesTab } from "@/components/wealth/broker-past";
import { NoIndia } from "./india";

/** India → Kite: the Kite account's portfolio, in INR. */
export function IndiaKitePage() {
  const search = indiaKiteRoute.useSearch();
  return <IndiaAccountPage segment="kite" tab={indiaAccountTab(search.tab)} sort={positionSort(search.sort)} />;
}

/** India → Coin: the Coin account's portfolio, in INR. */
export function IndiaCoinPage() {
  const search = indiaCoinRoute.useSearch();
  return <IndiaAccountPage segment="coin" tab={indiaAccountTab(search.tab)} sort={positionSort(search.sort)} />;
}

function Header({ segment, account }: { segment: IndiaSegment; account: IndiaAccount | null }) {
  const info = INDIA_TAB[segment];
  return (
    <div className="flex items-start gap-3">
      <BankLogo bankCode={account?.bank_code ?? info.bankCode} size="lg" decorative className="mt-1" />
      <div className="min-w-0 flex-1">
        <PageHeader eyebrow="India" title={account?.name ?? `Zerodha ${info.label}`} description={info.holds} />
      </div>
    </div>
  );
}

function NoAccount({ segment }: { segment: IndiaSegment }) {
  const other: IndiaSegment = segment === "kite" ? "coin" : "kite";
  return (
    <Card>
      <EmptyState
        title={`No Zerodha ${INDIA_TAB[segment].label} account in this ledger`}
        action={
          <Link to="/india" className="text-sm text-accent hover:underline">
            Back to India
          </Link>
        }
      >
        This ledger's India accounts are on the Overview; its Zerodha {INDIA_TAB[other].label} account, if it has one, is on its own tab.
      </EmptyState>
    </Card>
  );
}

function IndiaAccountPage({ segment, tab, sort }: { segment: IndiaSegment; tab: IndiaAccountTab; sort: PositionSort }) {
  const { profile_code: profileCode } = useActiveProfile();
  const overview = useIndiaOverview(profileCode);
  const o = overview.data;
  const account = o?.available ? indiaAccountFor(o.accounts, segment) : null;

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <Header segment={segment} account={account} />
      {overview.isLoading ? (
        <Card>
          <LoadingBlock className="h-72" />
        </Card>
      ) : overview.isError || !o ? (
        <Card>
          <ErrorState title="Couldn't load India" error={overview.error} onRetry={() => void overview.refetch()} />
        </Card>
      ) : !o.available ? (
        <NoIndia />
      ) : !account ? (
        <NoAccount segment={segment} />
      ) : (
        <Portfolio key={account.account_code} profileCode={profileCode} accountCode={account.account_code} segment={segment} tab={tab} sort={sort} />
      )}
    </div>
  );
}

function Portfolio({ profileCode, accountCode, segment, tab, sort }: { profileCode: string; accountCode: string; segment: IndiaSegment; tab: IndiaAccountTab; sort: PositionSort }) {
  const q = useBrokerPortfolio(profileCode, accountCode);
  const navigate = useNavigate({ from: INDIA_TAB[segment].path });
  const setTab = (t: string) => void navigate({ search: (s) => ({ ...s, tab: indiaAccountTab(t) === "past" ? "past" : undefined }), replace: true, resetScroll: false });
  const setSort = (x: PositionSort) => void navigate({ search: (s) => ({ ...s, sort: positionSortParam(x) }), replace: true, resetScroll: false });
  const p = q.data ?? null;

  if (q.isLoading)
    return (
      <Card>
        <LoadingBlock className="h-72" />
      </Card>
    );
  if (q.isError)
    return (
      <Card>
        <ErrorState title="Couldn't load the portfolio" error={q.error} onRetry={() => void q.refetch()} />
      </Card>
    );
  if (!p)
    return (
      <Card>
        <EmptyState title="Not synced yet">The portfolio shows after Zerodha {INDIA_TAB[segment].label}'s first sync.</EmptyState>
      </Card>
    );
  return (
    <>
      <PortfolioCard portfolio={p} />
      {(p.allocation.length > 0 || p.highlights) && (
        <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
          <AllocationCard portfolio={p} />
          <HighlightsCard portfolio={p} segment={segment} />
        </div>
      )}
      <SipsCard sips={p.sips} />
      <Tabs value={tab} onValueChange={setTab}>
        <TabsList className="mb-4">
          <TabsTrigger value="portfolio">Holdings</TabsTrigger>
          <TabsTrigger value="past">
            {basisWords(p.basis).past}
            {p.closed.length > 0 ? ` (${p.closed.length})` : ""}
          </TabsTrigger>
        </TabsList>
        <TabsContent value="portfolio">
          <PositionsCard portfolio={p} segment={segment} sort={sort} onSort={setSort} />
        </TabsContent>
        <TabsContent value="past">
          <PastNotesTab portfolio={p} linked={false} />
        </TabsContent>
      </Tabs>
    </>
  );
}
