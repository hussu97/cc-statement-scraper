import { useId, useState, type FormEvent } from "react";
import { holdingErrorMessage, useSaveHolding, type Holding } from "@/data/holdings";
import {
  CURRENCIES,
  INSTITUTION_MAX,
  LINK_MAX,
  NAME_MAX,
  NOTES_MAX,
  SYMBOL_MAX,
  emptyInvestmentForm,
  investmentToForm,
  linkRuleText,
  nameExample,
  validateInvestmentForm,
  type InvestmentForm,
  type InvestmentKind,
} from "@/lib/investments";
import { todayDubai } from "@/lib/dates";
import { Field, Input, Textarea } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Checkbox } from "@/components/ui/primitives";
import { useToast } from "@/components/ui/toast";
import { FormError, FormFooter } from "@/components/cash/bank-account-dialogs";

const INSTITUTION_EXAMPLE: Record<InvestmentKind, string> = {
  plan: "RL360",
  broker: "Interactive Brokers",
  security: "DFM",
  deposit: "Wio",
};

const LINK_HINT =
  "Payments whose description contains this (or is exactly this, below) are linked automatically and count as saving, not spending. Earlier payments are linked when you save. You can link or unlink any payment by hand from its transaction.";

/** A plan, broker account, share or fund, or fixed deposit: kind-specific fields. Owner only. */
export function InvestmentFormBody({
  profileCode,
  kind,
  holding,
  onDone,
  onBack,
}: {
  profileCode: string;
  kind: InvestmentKind;
  holding: Holding | null;
  onDone: () => void;
  onBack?: () => void;
}) {
  const save = useSaveHolding(profileCode);
  const toast = useToast();
  const today = todayDubai();
  const [form, setForm] = useState<InvestmentForm>(() => (holding ? investmentToForm(holding) : emptyInvestmentForm(kind)));
  const [error, setError] = useState<string | null>(null);
  const set = <K extends keyof InvestmentForm>(k: K, v: InvestmentForm[K]) => setForm((f) => ({ ...f, [k]: v }));
  const isDeposit = kind === "deposit";
  const exactHintId = useId();

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const v = validateInvestmentForm(form, today);
    if (!v.ok) {
      setError(v.error);
      return;
    }
    setError(null);
    const input = holding ? { ...v.input, holding_code: holding.holding_code } : v.input;
    save.mutate(input, {
      onSuccess: () => {
        toast({
          title: holding ? "Holding saved" : "Holding added",
          description: input.link_pattern ? `${linkRuleText(input.link_pattern, input.link_exact)}: linked to ${input.name}.` : input.name,
          tone: "positive",
        });
        onDone();
      },
      onError: (err) => setError(holdingErrorMessage(err)),
    });
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <Field label="Name" hint={`For example ${nameExample(kind)}`}>
        {(id, desc) => <Input id={id} aria-describedby={desc} autoComplete="off" maxLength={NAME_MAX} value={form.name} onChange={(e) => set("name", e.target.value)} autoFocus />}
      </Field>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-[minmax(0,1fr)_9rem]">
        <Field label="Institution (optional)">
          {(id) => (
            <Input id={id} autoComplete="off" maxLength={INSTITUTION_MAX} placeholder={INSTITUTION_EXAMPLE[kind]} value={form.institution} onChange={(e) => set("institution", e.target.value)} />
          )}
        </Field>
        <Field label="Currency">
          {(id) => (
            <div id={id}>
              <Select
                ariaLabel="Currency"
                className="w-full"
                value={form.currency}
                onValueChange={(v) => set("currency", v)}
                options={[...new Set([...CURRENCIES, form.currency])].map((c) => ({ value: c, label: c }))}
              />
            </div>
          )}
        </Field>
      </div>
      {kind === "security" && (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Field label="Units held" hint="Shares or fund units, as on your statement.">
            {(id, desc) => (
              <Input id={id} aria-describedby={desc} inputMode="decimal" autoComplete="off" placeholder="0" className="tabular" value={form.units} onChange={(e) => set("units", e.target.value)} />
            )}
          </Field>
          <Field label="Symbol (optional)">
            {(id) => <Input id={id} autoComplete="off" maxLength={SYMBOL_MAX} placeholder="EXCO" value={form.symbol} onChange={(e) => set("symbol", e.target.value)} />}
          </Field>
        </div>
      )}
      {isDeposit && (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Field label={`Principal in ${form.currency}`}>
            {(id) => (
              <Input id={id} inputMode="decimal" autoComplete="off" placeholder="0.00" className="tabular" value={form.principal} onChange={(e) => set("principal", e.target.value)} />
            )}
          </Field>
          <Field label="Profit rate, % a year">
            {(id) => <Input id={id} inputMode="decimal" autoComplete="off" placeholder="4.25" className="tabular" value={form.rate} onChange={(e) => set("rate", e.target.value)} />}
          </Field>
        </div>
      )}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label={isDeposit ? "Start date" : "Start date (optional)"} hint={isDeposit ? undefined : "When you started it. The link rule leaves payments from more than a week before it alone."}>
          {(id, desc) => <Input id={id} aria-describedby={desc} type="date" max={today} value={form.startOn} onChange={(e) => set("startOn", e.target.value)} />}
        </Field>
        {isDeposit && (
          <Field label="Maturity date">
            {(id) => <Input id={id} type="date" min={form.startOn || undefined} value={form.maturityOn} onChange={(e) => set("maturityOn", e.target.value)} />}
          </Field>
        )}
      </div>
      {isDeposit && <p className="-mt-2 text-xs text-muted">Its value is an estimate: the principal plus simple profit accrued to today, up to maturity.</p>}
      <Field label="Link payments (optional)" hint={LINK_HINT}>
        {(id, desc) => (
          <Input
            id={id}
            aria-describedby={desc}
            autoComplete="off"
            maxLength={LINK_MAX}
            placeholder={`e.g. ${INSTITUTION_EXAMPLE[kind]}`}
            value={form.linkPattern}
            onChange={(e) => set("linkPattern", e.target.value)}
          />
        )}
      </Field>
      <label className="-mt-2 flex items-start gap-2.5 text-[13px] text-ink">
        <Checkbox className="mt-0.5" checked={form.linkExact} onCheckedChange={(v) => set("linkExact", v === true)} aria-describedby={exactHintId} />
        <span>
          Match the whole description
          <span id={exactHintId} className="block text-xs text-muted">
            Use for short names: Wio shows RL360 payments as just “RI”. The description must be exactly the text above (any case), and 2 characters are enough.
          </span>
        </span>
      </label>
      <Field label="Notes (optional)">{(id) => <Textarea id={id} maxLength={NOTES_MAX} value={form.notes} onChange={(e) => set("notes", e.target.value)} />}</Field>
      <FormError error={error} />
      <FormFooter onCancel={onBack ?? onDone} cancel={onBack ? "Back" : undefined} pending={save.isPending} submit={holding ? "Save holding" : "Add holding"} />
    </form>
  );
}
