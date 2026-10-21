import { Link } from "@tanstack/react-router";
import { useActiveProfile } from "@/data/profile";
import { BankAccountsCard } from "@/components/cash/bank-accounts";
import { MonthCashCard, NetWorthHero, NetWorthHistoryCard, OwedCardsCard, WealthInsightsCard } from "@/components/wealth/wealth-cards";
import { InvestmentsCard } from "@/components/wealth/investments";

/** Wealth mode's home: net worth, its history, accounts and cards, investments, this month's cash flow, wealth insights. */
export function WealthOverviewPage() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  return (
    <div className="flex flex-col gap-6">
      <NetWorthHero profileCode={profileCode} />
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <NetWorthHistoryCard profileCode={profileCode} />
        <WealthInsightsCard profileCode={profileCode} />
      </div>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <BankAccountsCard
          profileCode={profileCode}
          isOwner={isOwner}
          eyebrow="Assets"
          headerLink={
            <Link to="/wealth/accounts" className="tap hidden text-[13px] text-accent hover:underline sm:inline">
              All accounts
            </Link>
          }
        />
        <OwedCardsCard profileCode={profileCode} />
      </div>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <InvestmentsCard profileCode={profileCode} />
        <MonthCashCard profileCode={profileCode} />
      </div>
    </div>
  );
}
