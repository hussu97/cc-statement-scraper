import { useMemo, useState, type FormEvent } from "react";
import { balanceErrorMessage, bankAccountErrorMessage, useCreateBankAccount, useRecordBalance, type CashAccount } from "@/data/cash";
import { useBanks } from "@/data/banks";
import {
  BANK_ACCOUNT_KINDS,
  balanceAsOf,
  bankAccountLabel,
  normalizeAccountRef,
  normalizeBalance,
  validateBankAccount,
  type BankAccountKind,
} from "@/lib/cash-flow";
import { formatMoney } from "@/lib/money";
import { todayDubai } from "@/lib/dates";
import { BankLogo } from "@/components/bank-logo";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Segmented } from "@/components/ui/segmented";
import { useToast } from "@/components/ui/toast";

export function FormError({ error }: { error: string | null }) {
  if (!error) return null;
  return (
    <p role="alert" className="rounded-md bg-danger-soft px-3 py-2 text-[13px] text-danger">
      {error}
    </p>
  );
}

export function FormFooter({ onCancel, pending, submit }: { onCancel: () => void; pending: boolean; submit: string }) {
  return (
    <div className="-mx-5 -mb-4 flex justify-end gap-2 border-t border-border px-5 py-3">
      <Button variant="ghost" onClick={onCancel}>
        Cancel
      </Button>
      <Button type="submit" variant="primary" loading={pending}>
        {submit}
      </Button>
    </div>
  );
}

// ── Update balance ─────────────────────────────────────────────────────────

export function UpdateBalanceDialog({ profileCode, account, onClose }: { profileCode: string; account: CashAccount | null; onClose: () => void }) {
  return (
    <Dialog
      open={!!account}
      onOpenChange={(o) => !o && onClose()}
      title="Update balance"
      description={account ? `${account.bank_code} · ${bankAccountLabel(account)}: the balance your bank shows now, or on a day you pick.` : undefined}
    >
      {account && <BalanceForm key={account.account_code} profileCode={profileCode} account={account} onDone={onClose} />}
    </Dialog>
  );
}

function BalanceForm({ profileCode, account, onDone }: { profileCode: string; account: CashAccount; onDone: () => void }) {
  const save = useRecordBalance(profileCode);
  const toast = useToast();
  const today = todayDubai();
  const [amount, setAmount] = useState("");
  const [date, setDate] = useState("");
  const [error, setError] = useState<string | null>(null);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const balance = normalizeBalance(amount);
    if (balance === null) {
      setError("Enter the balance as a number with at most two decimals, e.g. 12500 or -40.25.");
      return;
    }
    const asOf = balanceAsOf(date, today);
    if (asOf === undefined) {
      setError("A balance can't be dated in the future.");
      return;
    }
    setError(null);
    save.mutate(
      { account_code: account.account_code, balance, as_of: asOf },
      {
        onSuccess: () => {
          toast({ title: "Balance saved", description: `${bankAccountLabel(account)}: ${formatMoney(balance, { currency: account.currency })}.`, tone: "positive" });
          onDone();
        },
        onError: (err) => setError(balanceErrorMessage(err)),
      },
    );
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <Field label={`Balance (${account.currency})`} hint="As the bank shows it, e.g. 12500 or 12,500.50. Overdrawn: start with a minus.">
        {(id, desc) => (
          <Input
            id={id}
            aria-describedby={desc}
            inputMode="decimal"
            autoComplete="off"
            placeholder="0.00"
            className="tabular"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            autoFocus
          />
        )}
      </Field>
      <Field label="As of (optional)" hint="Leave empty for now. An earlier day counts as its closing balance.">
        {(id, desc) => <Input id={id} aria-describedby={desc} type="date" max={today} value={date} onChange={(e) => setDate(e.target.value)} />}
      </Field>
      <FormError error={error} />
      <FormFooter onCancel={onDone} pending={save.isPending} submit="Save balance" />
    </form>
  );
}

// ── Add bank account ───────────────────────────────────────────────────────

export function AddBankAccountDialog({ profileCode, open, onOpenChange }: { profileCode: string; open: boolean; onOpenChange: (o: boolean) => void }) {
  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="Add bank account"
      description="A current or savings account. Its alerts and balances then show up here."
    >
      {open && <BankAccountForm profileCode={profileCode} onDone={() => onOpenChange(false)} />}
    </Dialog>
  );
}

function BankAccountForm({ profileCode, onDone }: { profileCode: string; onDone: () => void }) {
  const banks = useBanks();
  const create = useCreateBankAccount(profileCode);
  const toast = useToast();
  const [bank, setBank] = useState("");
  const [kind, setKind] = useState<BankAccountKind>("current");
  const [ref, setRef] = useState("");
  const [nickname, setNickname] = useState("");
  const [error, setError] = useState<string | null>(null);

  const bankOptions = useMemo(
    () =>
      (banks.data ?? []).map((b) => ({
        value: b.bank_code,
        label: (
          <span className="inline-flex items-center gap-2">
            <BankLogo bankCode={b.bank_code} size="xs" decorative />
            {b.name}
          </span>
        ),
      })),
    [banks.data],
  );

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const problem = validateBankAccount({ bank_code: bank, account_ref: ref });
    if (problem) {
      setError(problem);
      return;
    }
    setError(null);
    const input = { bank_code: bank, kind, account_ref: normalizeAccountRef(ref), nickname };
    create.mutate(input, {
      onSuccess: () => {
        toast({ title: "Bank account added", description: `${bank} · ${bankAccountLabel(input)}. Record its balance to count it in your cash.`, tone: "positive" });
        onDone();
      },
      onError: (err) => setError(bankAccountErrorMessage(err)),
    });
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <Field label="Bank" hint={banks.isError ? "Couldn't load the banks. Close this and try again." : undefined}>
        {(id, desc) => (
          <div id={id} aria-describedby={desc}>
            <Select ariaLabel="Bank" placeholder={banks.isLoading ? "Loading banks…" : "Pick a bank"} className="w-full" value={bank || undefined} onValueChange={setBank} options={bankOptions} disabled={!banks.data} />
          </div>
        )}
      </Field>
      <Field label="Type">
        {(id) => (
          <div id={id}>
            <Segmented ariaLabel="Account type" value={kind} onChange={setKind} options={BANK_ACCOUNT_KINDS} />
          </div>
        )}
      </Field>
      <Field label="Account number ending" hint="The digits after the Xs in the bank's alerts, e.g. 810001. They match SMS alerts to this account.">
        {(id, desc) => (
          <Input id={id} aria-describedby={desc} inputMode="numeric" autoComplete="off" placeholder="810001" className="tabular" value={ref} onChange={(e) => setRef(e.target.value)} />
        )}
      </Field>
      <Field label="Nickname (optional)" hint="For example Salary account">
        {(id, desc) => <Input id={id} aria-describedby={desc} autoComplete="off" maxLength={60} value={nickname} onChange={(e) => setNickname(e.target.value)} />}
      </Field>
      <FormError error={error} />
      <FormFooter onCancel={onDone} pending={create.isPending} submit="Add account" />
    </form>
  );
}
