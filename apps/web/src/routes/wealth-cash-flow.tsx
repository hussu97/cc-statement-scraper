import { useNavigate } from "@tanstack/react-router";
import { wealthCashFlowRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useCashPosition } from "@/data/cash";
import { accountLabel } from "@/data/overview";
import { monthStart, todayDubai } from "@/lib/dates";
import { PageHeader } from "@/components/ui/display";
import { ANY, Select } from "@/components/ui/select";
import { CashFlowCard } from "@/components/cash/cash-flow-card";

/** Each month's money in and out, for the ledger or one bank account (Wealth mode). */
export function CashFlowPage() {
  const { profile_code: profileCode } = useActiveProfile();
  const search = wealthCashFlowRoute.useSearch();
  const navigate = useNavigate({ from: "/wealth/cash-flow" });
  const thisMonth = monthStart(todayDubai());
  const month = search.month && search.month <= thisMonth ? search.month : thisMonth;
  const cash = useCashPosition(profileCode);
  const bankAccounts = cash.data?.accounts ?? [];
  // An ?account= that isn't one of the ledger's bank accounts (any more) shows every account.
  const account = search.account && (!cash.data || bankAccounts.some((a) => a.account_code === search.account)) ? search.account : undefined;
  const go = (patch: { month?: string; account?: string }) => {
    const next = { month, account, ...patch };
    void navigate({ search: { month: next.month === thisMonth ? undefined : next.month, account: next.account }, replace: true });
  };
  // The Unfiled links open one account's ledger: the chosen one, or the ledger's only one.
  const unfiledAccount = account ?? (bankAccounts.length === 1 ? bankAccounts[0]?.account_code : undefined);

  return (
    <div className="animate-fade-in">
      <PageHeader
        title="Cash flow"
        description="Where each month's money came from and went: income, support and saving, spending, and what's still unfiled."
        actions={
          bankAccounts.length > 1 ? (
            <Select
              ariaLabel="Account"
              size="sm"
              className="w-56 max-w-full"
              value={account ?? ANY}
              onValueChange={(v) => go({ account: v === ANY ? undefined : v })}
              options={[{ value: ANY, label: "All accounts" }, ...bankAccounts.map((a) => ({ value: a.account_code, label: accountLabel(a) }))]}
            />
          ) : undefined
        }
      />
      <CashFlowCard
        profileCode={profileCode}
        month={month}
        thisMonth={thisMonth}
        onMonth={(m) => go({ month: m })}
        account={account}
        unfiledAccount={unfiledAccount}
      />
    </div>
  );
}
