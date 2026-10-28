import { useNavigate } from "@tanstack/react-router";
import { wealthAccountRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useCashPosition } from "@/data/cash";
import { isNotFound, useAccountLedger } from "@/data/wealth";
import { accountMonthStart, shiftAccountMonth } from "@/lib/wealth";
import { monthEnd, monthStart, todayDubai } from "@/lib/dates";
import { ACC_RE, AccountHeader, AccountNotFound, AccountStatement } from "@/components/wealth/account-page";
import { AccountInvestmentBar } from "@/components/wealth/account-investment";

/**
 * One bank account (Wealth → Accounts): its balance, balance over time, and the month as a
 * statement. A synced broker account (Swissquote, Zerodha) reads the same here; its portfolio is
 * on its own page under Investments (routes/wealth-portfolio.tsx).
 */
export function AccountPage() {
  const { accountCode } = wealthAccountRoute.useParams();
  if (!ACC_RE.test(accountCode)) return <AccountNotFound />;
  return <AccountView key={accountCode} accountCode={accountCode} />;
}

function AccountView({ accountCode }: { accountCode: string }) {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const search = wealthAccountRoute.useSearch();
  const navigate = useNavigate({ from: "/wealth/accounts/$accountCode" });
  const today = todayDubai();
  const start = accountMonthStart(search.month, today);
  const ledger = useAccountLedger(profileCode, accountCode, { from: start, to: monthEnd(start) });
  const cash = useCashPosition(profileCode);
  const position = cash.data?.accounts.find((a) => a.account_code === accountCode) ?? null;
  const setMonth = (by: number) => void navigate({ search: (s) => ({ ...s, month: shiftAccountMonth(start, by, today) }), replace: true, resetScroll: false });

  if (ledger.isError && isNotFound(ledger.error)) return <AccountNotFound />;

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <AccountHeader back={{ to: "/wealth/accounts", label: "Accounts" }} account={ledger.data?.account ?? position} />
      <AccountInvestmentBar profileCode={profileCode} account={position} isOwner={isOwner} />
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
    </div>
  );
}
