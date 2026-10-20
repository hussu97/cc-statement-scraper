import { useActiveProfile } from "@/data/profile";
import { PageHeader } from "@/components/ui/display";
import { BankAccountsCard } from "@/components/cash/bank-accounts";

/** The ledger's bank accounts (Wealth mode): balances, Update balance, Add account; each opens its ledger. */
export function AccountsPage() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  return (
    <div className="animate-fade-in">
      <PageHeader title="Accounts" description="Your bank accounts and their balances. Open one for its transactions, month by month, with the balance after each." />
      <BankAccountsCard profileCode={profileCode} isOwner={isOwner} />
    </div>
  );
}
