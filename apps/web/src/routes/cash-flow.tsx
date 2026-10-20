import { useNavigate, useSearch } from "@tanstack/react-router";
import { useActiveProfile } from "@/data/profile";
import { useCashPosition } from "@/data/cash";
import { monthStart, todayDubai } from "@/lib/dates";
import { PageHeader } from "@/components/ui/display";
import { BankAccountsCard } from "@/components/cash/bank-accounts";
import { CashFlowCard } from "@/components/cash/cash-flow-card";

/** Bank accounts, their balances, and each month's money in and out (Phase 2d). */
export function CashFlowPage() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const search = useSearch({ from: "/app/cash-flow" });
  const navigate = useNavigate();
  const thisMonth = monthStart(todayDubai());
  const month = search.month && search.month <= thisMonth ? search.month : thisMonth;
  const setMonth = (m: string) => void navigate({ to: "/cash-flow", search: m === thisMonth ? {} : { month: m }, replace: true });
  // The Unfiled links can name the bank account only when there is exactly one.
  const cash = useCashPosition(profileCode);
  const bankAccounts = cash.data?.accounts ?? [];
  const unfiledAccount = bankAccounts.length === 1 ? bankAccounts[0]?.account_code : undefined;

  return (
    <div className="animate-fade-in">
      <PageHeader title="Cash flow" description="Your bank balances, and where each month's money came from and went." />
      <div className="flex flex-col gap-6">
        <BankAccountsCard profileCode={profileCode} isOwner={isOwner} />
        <CashFlowCard profileCode={profileCode} month={month} thisMonth={thisMonth} onMonth={setMonth} unfiledAccount={unfiledAccount} />
      </div>
    </div>
  );
}
