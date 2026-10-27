import { useState, type FormEvent } from "react";
import { useAddAccountEntry } from "@/data/notes";
import type { CashAccount } from "@/data/cash";
import { errorMessage } from "@/data/api";
import { bankAccountLabel } from "@/lib/cash-flow";
import { cleanDecimal } from "@/lib/notes";
import { todayDubai } from "@/lib/dates";
import { formatMoney } from "@/lib/money";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { Segmented } from "@/components/ui/segmented";
import { useToast } from "@/components/ui/toast";
import { FormError, FormFooter } from "@/components/cash/bank-account-dialogs";

const DIRECTIONS: { value: "credit" | "debit"; label: string }[] = [
  { value: "credit", label: "Deposit" },
  { value: "debit", label: "Withdrawal" },
];

/** A deposit or withdrawal typed on an account no SMS or statement reaches (a broker's cash). */
export function AccountEntryDialog({ profileCode, account, onClose }: { profileCode: string; account: CashAccount | null; onClose: () => void }) {
  return (
    <Dialog
      open={!!account}
      onOpenChange={(o) => !o && onClose()}
      title="Add a deposit or withdrawal"
      description={account ? `${account.bank_code} · ${bankAccountLabel(account)}: money in or out that no alert or statement brings in. Notes post their own purchases and payments.` : undefined}
    >
      {account && <EntryForm profileCode={profileCode} account={account} onDone={onClose} />}
    </Dialog>
  );
}

function EntryForm({ profileCode, account, onDone }: { profileCode: string; account: CashAccount; onDone: () => void }) {
  const add = useAddAccountEntry(profileCode);
  const toast = useToast();
  const [direction, setDirection] = useState<"credit" | "debit">("credit");
  const [amount, setAmount] = useState("");
  const [date, setDate] = useState(todayDubai());
  const [description, setDescription] = useState("");
  const [error, setError] = useState<string | null>(null);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const value = cleanDecimal(amount);
    if (!value || Number(value) <= 0 || !/^\d+(\.\d{1,2})?$/.test(value)) {
      setError("Enter the amount, e.g. 25000 or 25,000.50.");
      return;
    }
    setError(null);
    add.mutate(
      { account_code: account.account_code, direction, amount: value, entry_date: date, description },
      {
        onSuccess: () => {
          toast({ title: direction === "credit" ? "Deposit added" : "Withdrawal added", description: formatMoney(value, { currency: account.currency }), tone: "positive" });
          onDone();
        },
        onError: (err) => setError(errorMessage(err)),
      },
    );
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <Segmented ariaLabel="Direction" value={direction} onChange={setDirection} options={DIRECTIONS} />
      <Field label={`Amount (${account.currency})`}>
        {(id) => <Input id={id} inputMode="decimal" className="tabular" placeholder="25000" value={amount} onChange={(e) => setAmount(e.target.value)} />}
      </Field>
      <Field label="Date" hint="The day it reached (or left) the account.">
        {(id, desc) => <Input id={id} aria-describedby={desc} type="date" max={todayDubai()} value={date} onChange={(e) => setDate(e.target.value)} />}
      </Field>
      <Field label="Description (optional)" hint="For example Transfer from Wio">
        {(id, desc) => <Input id={id} aria-describedby={desc} maxLength={80} value={description} onChange={(e) => setDescription(e.target.value)} />}
      </Field>
      <FormError error={error} />
      <FormFooter onCancel={onDone} pending={add.isPending} submit="Add" />
    </form>
  );
}
