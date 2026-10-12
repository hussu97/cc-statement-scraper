import { useMemo, useState, type FormEvent } from "react";
import {
  dateToMonthInput,
  monthInputToDate,
  useSaveBudget,
  validateBudget,
  type BudgetInput,
} from "@/data/budgets";
import { orderCategories, useCategories } from "@/data/rules";
import { useAccounts } from "@/data/cards";
import { accountLabel } from "@/data/overview";
import { BankLogo } from "@/components/bank-logo";
import { errorMessage } from "@/data/api";
import { formatMonth } from "@/lib/dates";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Dot } from "@/components/ui/display";
import { Field, Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { useToast } from "@/components/ui/toast";

/** Select can't hold null: this sentinel means "All spending" / "All cards". */
const ALL = "__all";
const PICKABLE_KINDS = new Set(["spend", "fee"]);

export function BudgetDialog({
  open,
  onOpenChange,
  profileCode,
  initial,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  profileCode: string;
  initial: BudgetInput;
}) {
  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title={initial.budget_code ? "Edit budget" : "New budget"}
      description="A monthly limit for all spending or one category, on every card or just one."
    >
      {/* Remount per open so the form starts from `initial`. */}
      {open && <BudgetForm key={initial.budget_code ?? "new"} profileCode={profileCode} initial={initial} onDone={() => onOpenChange(false)} />}
    </Dialog>
  );
}

function BudgetForm({ profileCode, initial, onDone }: { profileCode: string; initial: BudgetInput; onDone: () => void }) {
  const cats = useCategories(profileCode);
  const accounts = useAccounts(profileCode);
  const save = useSaveBudget(profileCode);
  const toast = useToast();
  const [card, setCard] = useState(initial.account_code ?? ALL);
  const [category, setCategory] = useState(initial.category_code ?? ALL);
  const [amount, setAmount] = useState(initial.amount_aed);
  const [fromMonth, setFromMonth] = useState(dateToMonthInput(initial.effective_from));
  const [toMonth, setToMonth] = useState(dateToMonthInput(initial.effective_to));
  const [error, setError] = useState<string | null>(null);

  const options = useMemo(() => {
    const list = orderCategories(
      (cats.data ?? []).filter((c) => (!c.archived_at && PICKABLE_KINDS.has(c.kind)) || c.category_code === initial.category_code),
    );
    return [
      { value: ALL, label: "All spending" },
      ...list.map((c) => ({
        value: c.category_code,
        label: (
          <span className={c.depth ? "inline-flex items-center gap-2 pl-3" : "inline-flex items-center gap-2"}>
            <Dot token={c.color_token} />
            {c.name}
          </span>
        ),
      })),
    ];
  }, [cats.data, initial.category_code]);

  const cardOptions = useMemo(
    () => [
      { value: ALL, label: "All cards" },
      ...(accounts.data ?? [])
        .filter((a) => a.status === "active" || a.account_code === initial.account_code)
        .map((a) => ({
          value: a.account_code,
          label: (
            <span className="inline-flex items-center gap-2">
              <BankLogo bankCode={a.bank_code} size="xs" decorative />
              {accountLabel(a)}
              <span className="text-muted">{(a.cards ?? []).map((c) => `•${c.last4}`).join(" ")}</span>
            </span>
          ),
        })),
    ],
    [accounts.data, initial.account_code],
  );

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const input: BudgetInput = {
      budget_code: initial.budget_code,
      account_code: card === ALL ? null : card,
      category_code: category === ALL ? null : category,
      amount_aed: amount.replace(/,/g, "").trim(),
      effective_from: monthInputToDate(fromMonth),
      effective_to: toMonth ? monthInputToDate(toMonth) : null,
    };
    const problem = validateBudget(input);
    if (problem) {
      setError(problem);
      return;
    }
    setError(null);
    save.mutate(input, {
      onSuccess: () => {
        toast({ title: initial.budget_code ? "Budget updated" : "Budget created", description: `Applies from ${formatMonth(input.effective_from)}.`, tone: "positive" });
        onDone();
      },
      onError: (err) => setError(errorMessage(err)),
    });
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <Field label="Card" hint={accounts.isError ? "Couldn't load cards; you can still budget every card." : "Optional: count only one card's spending."}>
        {(id, desc) => (
          <div id={id} aria-describedby={desc}>
            <Select ariaLabel="Card" className="w-full" value={card} onValueChange={setCard} options={cardOptions} disabled={accounts.isLoading} />
          </div>
        )}
      </Field>
      <Field label="Category" hint={cats.isError ? "Couldn't load categories; you can still budget all spending." : undefined}>
        {(id, desc) => (
          <div id={id} aria-describedby={desc}>
            <Select ariaLabel="Category" className="w-full" value={category} onValueChange={setCategory} options={options} disabled={cats.isLoading} />
          </div>
        )}
      </Field>
      <Field label="Monthly amount (AED)" hint="For example 1500 or 1500.50">
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
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Starts">
          {(id, desc) => <Input id={id} aria-describedby={desc} type="month" value={fromMonth} onChange={(e) => setFromMonth(e.target.value)} />}
        </Field>
        <Field label="Ends (optional)" hint="Last month it applies">
          {(id, desc) => <Input id={id} aria-describedby={desc} type="month" min={fromMonth || undefined} value={toMonth} onChange={(e) => setToMonth(e.target.value)} />}
        </Field>
      </div>
      {error && (
        <p role="alert" className="rounded-md bg-danger-soft px-3 py-2 text-[13px] text-danger">
          {error}
        </p>
      )}
      <div className="-mx-5 -mb-4 flex justify-end gap-2 border-t border-border px-5 py-3">
        <Button variant="ghost" onClick={onDone}>
          Cancel
        </Button>
        <Button type="submit" variant="primary" loading={save.isPending}>
          {initial.budget_code ? "Save changes" : "Create budget"}
        </Button>
      </div>
    </form>
  );
}
