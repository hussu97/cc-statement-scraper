import { useState, type FormEvent } from "react";
import { holdingErrorMessage, useCloseHolding, useSaveHolding, type Holding } from "@/data/holdings";
import {
  EMPTY_HOLDING_FORM,
  FINENESS,
  KARATS,
  METALS,
  NAME_MAX,
  NOTES_MAX,
  WEIGHT_UNITS,
  draftImagePath,
  formOptions,
  formatFineness,
  formatWeight,
  holdingToForm,
  toGrams,
  updateHoldingForm,
  validateHoldingForm,
  type Fineness,
  type HoldingForm,
  type HoldingShape,
  type Karat,
  type Metal,
  type WeightUnit,
} from "@/lib/holdings";
import { todayDubai } from "@/lib/dates";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Textarea } from "@/components/ui/input";
import { Segmented } from "@/components/ui/segmented";
import { useToast } from "@/components/ui/toast";
import { FormError, FormFooter } from "@/components/cash/bank-account-dialogs";
import { ConfirmDialog } from "@/components/rules/shared";
import { HOLDING_KINDS, kindLabel, kindOf, type HoldingKind } from "@/lib/investments";
import { HoldingImage, KindIcon } from "./holding-image";
import { InvestmentFormBody } from "./investment-form";

const KIND_HINT: Record<HoldingKind, string> = {
  metal: "Bars, coins or jewellery by weight, valued at Dubai's retail rates.",
  plan: "A savings or insurance plan you pay into, like RL360. You enter its value from the statement.",
  broker: "An account valued as a whole: IBKR, Swissquote, Sarwa. You enter its value.",
  security: "Shares or a fund: the units you hold times a price you enter.",
  deposit: "A fixed deposit: principal, profit rate and maturity. Its value accrues day by day.",
};

/**
 * Add (holding = null) or edit a holding. Adding starts with the kind; editing keeps it (values
 * and flows belong to that kind). Owner only; the caller decides.
 */
export function HoldingDialog({ profileCode, open, holding, onClose }: { profileCode: string; open: boolean; holding: Holding | null; onClose: () => void }) {
  const [picked, setPicked] = useState<HoldingKind | null>(null);
  const kind = holding ? kindOf(holding) : picked;
  const close = () => {
    setPicked(null);
    onClose();
  };
  return (
    <Dialog
      open={open}
      onOpenChange={(o) => !o && close()}
      title={holding ? `Edit ${holding.name}` : kind ? `Add ${kindLabel(kind).toLowerCase()}` : "Add holding"}
      description={kind ? KIND_HINT[kind] : "What kind of investment is it?"}
    >
      {open &&
        (kind === null ? (
          <KindPicker onPick={setPicked} />
        ) : kind === "metal" ? (
          <HoldingFormBody key={holding?.holding_code ?? "new"} profileCode={profileCode} holding={holding} onDone={close} onBack={holding ? undefined : () => setPicked(null)} />
        ) : (
          <InvestmentFormBody
            key={holding?.holding_code ?? `new-${kind}`}
            profileCode={profileCode}
            kind={kind}
            holding={holding}
            onDone={close}
            onBack={holding ? undefined : () => setPicked(null)}
          />
        ))}
    </Dialog>
  );
}

function KindPicker({ onPick }: { onPick: (k: HoldingKind) => void }) {
  return (
    <ul className="flex flex-col gap-2" aria-label="Kind of investment">
      {HOLDING_KINDS.map((k) => (
        <li key={k.value}>
          <button
            type="button"
            onClick={() => onPick(k.value)}
            className="tap flex w-full items-start gap-3 rounded-md border border-border bg-surface px-3 py-2.5 text-left transition-colors hover:border-border-strong hover:bg-surface-2"
          >
            <KindIcon kind={k.value} className="mt-0.5 size-5 shrink-0 text-ink-2" />
            <span className="min-w-0">
              <span className="block text-sm font-medium text-ink">{k.label}</span>
              <span className="block text-[12px] text-muted">{KIND_HINT[k.value]}</span>
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}

function HoldingFormBody({ profileCode, holding, onDone, onBack }: { profileCode: string; holding: Holding | null; onDone: () => void; onBack?: () => void }) {
  const save = useSaveHolding(profileCode);
  const toast = useToast();
  const today = todayDubai();
  const [form, setForm] = useState<HoldingForm>(() => (holding ? holdingToForm(holding) : EMPTY_HOLDING_FORM));
  const [error, setError] = useState<string | null>(null);
  const set = <K extends keyof HoldingForm>(k: K, v: HoldingForm[K]) => setForm((f) => updateHoldingForm(f, { [k]: v }));
  // The weight in grams, shown as it will be saved (an exact conversion, not a value).
  const grams = form.weight.trim() ? toGrams(form.weight, form.unit) : null;

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const v = validateHoldingForm(form, today);
    if (!v.ok) {
      setError(v.error);
      return;
    }
    setError(null);
    const input = holding ? { ...v.input, holding_code: holding.holding_code } : v.input;
    save.mutate(input, {
      onSuccess: () => {
        toast({ title: holding ? "Holding saved" : "Holding added", description: `${input.name}: ${formatWeight(input.grams)}.`, tone: "positive" });
        onDone();
      },
      onError: (err) => setError(holdingErrorMessage(err)),
    });
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <div className="flex items-center gap-4">
        <HoldingImage imagePath={draftImagePath(form.metal, form.form)} metal={form.metal} form={form.form} size="lg" />
        <Field label="Form" className="min-w-0 flex-1">
          {(id) => (
            <div id={id}>
              <Segmented ariaLabel="Form" value={form.form} onChange={(v: HoldingShape) => set("form", v)} options={formOptions(form.metal)} />
            </div>
          )}
        </Field>
      </div>
      <Field label="Name" hint="For example Ten tola bar, Wedding bangles">
        {(id, desc) => (
          <Input id={id} aria-describedby={desc} autoComplete="off" maxLength={NAME_MAX} value={form.name} onChange={(e) => set("name", e.target.value)} autoFocus />
        )}
      </Field>
      <Field label="Metal">
        {(id) => (
          <div id={id}>
            <Segmented ariaLabel="Metal" value={form.metal} onChange={(m: Metal) => set("metal", m)} options={[...METALS]} />
          </div>
        )}
      </Field>
      <Field label="Weight" hint={grams ? (form.unit === "g" ? undefined : `= ${formatWeight(grams)}${form.unit === "tola" ? " (1 tola = 11.6638 g)" : ""}`) : undefined}>
        {(id, desc) => (
          <div className="flex flex-wrap items-center gap-2">
            <Input
              id={id}
              aria-describedby={desc}
              inputMode="decimal"
              autoComplete="off"
              placeholder="0"
              className="tabular w-36 flex-1"
              value={form.weight}
              onChange={(e) => set("weight", e.target.value)}
            />
            <Segmented ariaLabel="Weight unit" value={form.unit} onChange={(u: WeightUnit) => set("unit", u)} options={WEIGHT_UNITS.map((u) => ({ value: u.value, label: u.label }))} />
          </div>
        )}
      </Field>
      {form.metal === "gold" ? (
        <>
          <Field label="Karat">
            {(id) => (
              <div id={id}>
                <Segmented
                  ariaLabel="Karat"
                  value={String(form.karat)}
                  onChange={(k) => set("karat", Number(k) as Karat)}
                  options={KARATS.map((k) => ({ value: String(k), label: `${k}K` }))}
                />
              </div>
            )}
          </Field>
          {form.karat === 24 && (
            <Field label="Fineness" hint="Stamped on the bar. Dubai's 24K rate is for 999.9; a lower fineness is valued in proportion.">
              {(id, desc) => (
                <div id={id} aria-describedby={desc}>
                  <Segmented
                    ariaLabel="Fineness"
                    value={String(form.fineness)}
                    onChange={(f) => set("fineness", Number(f) as Fineness)}
                    options={FINENESS.map((f) => ({ value: String(f), label: formatFineness(f) }))}
                  />
                </div>
              )}
            </Field>
          )}
        </>
      ) : (
        <Field label="Purity" hint="Parts per thousand, as stamped: 999 for fine silver, 925 for sterling.">
          {(id, desc) => (
            <Input id={id} aria-describedby={desc} inputMode="decimal" autoComplete="off" className="tabular w-36" value={form.purity} onChange={(e) => set("purity", e.target.value)} />
          )}
        </Field>
      )}
      <Field label="Cost paid in AED (optional)" hint="The total you paid. With it, Bank Ledger shows your gain.">
        {(id, desc) => (
          <Input id={id} aria-describedby={desc} inputMode="decimal" autoComplete="off" placeholder="0.00" className="tabular" value={form.cost} onChange={(e) => set("cost", e.target.value)} />
        )}
      </Field>
      <Field label="Date bought (optional)" hint="The value chart counts it from this day.">
        {(id, desc) => <Input id={id} aria-describedby={desc} type="date" max={today} value={form.acquiredOn} onChange={(e) => set("acquiredOn", e.target.value)} />}
      </Field>
      <Field label="Notes (optional)">
        {(id) => <Textarea id={id} maxLength={NOTES_MAX} value={form.notes} onChange={(e) => set("notes", e.target.value)} />}
      </Field>
      <FormError error={error} />
      <FormFooter onCancel={onBack ?? onDone} cancel={onBack ? "Back" : undefined} pending={save.isPending} submit={holding ? "Save holding" : "Add holding"} />
    </form>
  );
}

/** Confirm, then close a holding: it stops counting (the record is kept). */
export function CloseHoldingDialog({ profileCode, holding, onClose }: { profileCode: string; holding: Holding | null; onClose: () => void }) {
  const close = useCloseHolding(profileCode);
  const toast = useToast();
  return (
    <ConfirmDialog
      open={!!holding}
      onOpenChange={(o) => {
        if (!o) {
          onClose();
          close.reset();
        }
      }}
      title="Close this holding?"
      confirmLabel="Close holding"
      pending={close.isPending}
      error={close.error ? new Error(holdingErrorMessage(close.error)) : null}
      onConfirm={() =>
        holding &&
        close.mutate(holding.holding_code, {
          onSuccess: () => {
            toast({ title: "Holding closed", description: `${holding.name} no longer counts in your investments.`, tone: "positive" });
            onClose();
          },
        })
      }
    >
      Sold or given away? “{holding?.name}” stops counting in your investments and net worth. Bank Ledger keeps its record.
    </ConfirmDialog>
  );
}
