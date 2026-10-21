import { useState, type FormEvent } from "react";
import { holdingErrorMessage, useAddHoldingFlow, useRecordHoldingValue, useRemoveHoldingFlow, type Holding, type HoldingFlow } from "@/data/holdings";
import { FLOW_KINDS, FLOW_KIND_LABEL, FLOW_NOTES_MAX, formatUnitPrice, formatUnits, kindOf, validateFlowForm, validateValueForm, valueInput, type FlowKind } from "@/lib/investments";
import { formatDate, todayDubai } from "@/lib/dates";
import { formatMoney } from "@/lib/money";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { Segmented } from "@/components/ui/segmented";
import { useToast } from "@/components/ui/toast";
import { FormError, FormFooter } from "@/components/cash/bank-account-dialogs";
import { ConfirmDialog } from "@/components/rules/shared";

// ── Update value ───────────────────────────────────────────────────────────

/** Record a plan's or broker account's value, or a share's unit price, as of a date. Owner only. */
export function UpdateValueDialog({ profileCode, holding, onClose }: { profileCode: string; holding: Holding | null; onClose: () => void }) {
  const isPrice = valueInput(holding?.kind) === "unit_price";
  return (
    <Dialog
      open={!!holding}
      onOpenChange={(o) => !o && onClose()}
      title={holding ? `Update ${holding.name}` : "Update value"}
      description={
        isPrice
          ? "Enter one unit's price from your broker or the exchange. Bank Ledger multiplies it by the units you hold."
          : "Enter the value on your latest statement or app. Each value is kept, so the history shows how it moved."
      }
      className="max-w-md"
    >
      {holding && <ValueFormBody key={holding.holding_code} profileCode={profileCode} holding={holding} onDone={onClose} />}
    </Dialog>
  );
}

function ValueFormBody({ profileCode, holding, onDone }: { profileCode: string; holding: Holding; onDone: () => void }) {
  const record = useRecordHoldingValue(profileCode);
  const toast = useToast();
  const today = todayDubai();
  const [amount, setAmount] = useState("");
  const [asOf, setAsOf] = useState(today);
  const [error, setError] = useState<string | null>(null);
  const currency = holding.currency ?? "AED";
  const isPrice = valueInput(holding.kind) === "unit_price";

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const v = validateValueForm(holding.kind, { amount, asOf }, today);
    if (!v.ok) {
      setError(v.error);
      return;
    }
    setError(null);
    record.mutate(
      { holding_code: holding.holding_code, ...v.input },
      {
        onSuccess: () => {
          toast({ title: "Value recorded", description: `${holding.name}: ${isPrice ? `${formatUnitPrice(v.input.unit_price, currency)} a unit` : formatMoney(v.input.value, { currency })}, ${formatDate(v.input.as_of ?? today)}.`, tone: "positive" });
          onDone();
        },
        onError: (err) => setError(holdingErrorMessage(err)),
      },
    );
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <Field label={isPrice ? `Price of one unit in ${currency}` : `Value in ${currency}`} hint={isPrice && holding.units ? `You hold ${formatUnits(holding.units)} units.` : undefined}>
        {(id, desc) => (
          <Input id={id} aria-describedby={desc} inputMode="decimal" autoComplete="off" placeholder="0.00" className="tabular" value={amount} onChange={(e) => setAmount(e.target.value)} autoFocus />
        )}
      </Field>
      <Field label="As of">{(id) => <Input id={id} type="date" max={today} value={asOf} onChange={(e) => setAsOf(e.target.value)} />}</Field>
      <FormError error={error} />
      <FormFooter onCancel={onDone} pending={record.isPending} submit="Record value" />
    </form>
  );
}

// ── Add flow ───────────────────────────────────────────────────────────────

const FLOW_HINT: Record<FlowKind, string> = {
  contribution: "Money you put in that isn't a payment in this ledger, e.g. a transfer from another bank.",
  withdrawal: "Money you took out of it.",
  income: "A dividend, interest or profit paid out to you.",
};

/** A contribution, withdrawal or income not paid through the ledger. Owner only. */
export function AddFlowDialog({ profileCode, holding, open, onClose }: { profileCode: string; holding: Holding; open: boolean; onClose: () => void }) {
  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()} title={`Add to ${holding.name}`} description="Payments made from your cards and accounts are better linked from the transaction itself." className="max-w-md">
      {open && <FlowFormBody profileCode={profileCode} holding={holding} onDone={onClose} />}
    </Dialog>
  );
}

function FlowFormBody({ profileCode, holding, onDone }: { profileCode: string; holding: Holding; onDone: () => void }) {
  const add = useAddHoldingFlow(profileCode);
  const toast = useToast();
  const today = todayDubai();
  const currency = holding.currency ?? "AED";
  const [f, setF] = useState({ kind: "contribution" as FlowKind, date: today, amount: "", amountAed: "", notes: "" });
  const [error, setError] = useState<string | null>(null);
  const set = <K extends keyof typeof f>(k: K, v: (typeof f)[K]) => setF((x) => ({ ...x, [k]: v }));

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const v = validateFlowForm(currency, f, today);
    if (!v.ok) {
      setError(v.error);
      return;
    }
    setError(null);
    add.mutate(
      { holding_code: holding.holding_code, ...v.input },
      {
        onSuccess: () => {
          toast({ title: `${FLOW_KIND_LABEL[v.input.kind]} recorded`, description: `${formatMoney(v.input.amount, { currency })} on ${formatDate(v.input.flow_date)}.`, tone: "positive" });
          onDone();
        },
        onError: (err) => setError(holdingErrorMessage(err)),
      },
    );
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <Field label="What happened" hint={FLOW_HINT[f.kind]}>
        {(id, desc) => (
          <div id={id} aria-describedby={desc}>
            <Segmented ariaLabel="What happened" value={f.kind} onChange={(k: FlowKind) => set("kind", k)} options={[...FLOW_KINDS]} />
          </div>
        )}
      </Field>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label={`Amount in ${currency}`}>
          {(id) => <Input id={id} inputMode="decimal" autoComplete="off" placeholder="0.00" className="tabular" value={f.amount} onChange={(e) => set("amount", e.target.value)} autoFocus />}
        </Field>
        <Field label="Date">{(id) => <Input id={id} type="date" max={today} value={f.date} onChange={(e) => set("date", e.target.value)} />}</Field>
      </div>
      {kindOf(holding) !== "metal" && currency !== "AED" && (
        <Field label="In AED (optional)" hint={currency === "USD" ? "Leave empty to convert at the 3.6725 peg." : "Leave empty to convert at the day's rate."}>
          {(id, desc) => (
            <Input id={id} aria-describedby={desc} inputMode="decimal" autoComplete="off" placeholder="0.00" className="tabular" value={f.amountAed} onChange={(e) => set("amountAed", e.target.value)} />
          )}
        </Field>
      )}
      <Field label="Note (optional)">{(id) => <Input id={id} autoComplete="off" maxLength={FLOW_NOTES_MAX} value={f.notes} onChange={(e) => set("notes", e.target.value)} />}</Field>
      <FormError error={error} />
      <FormFooter onCancel={onDone} pending={add.isPending} submit="Add" />
    </form>
  );
}

// ── Remove flow ────────────────────────────────────────────────────────────

/** Remove an entered or linked flow. A linked payment is unlinked for good: it counts by its category again and the rule leaves it alone. */
export function RemoveFlowDialog({ profileCode, flow, currency, onClose }: { profileCode: string; flow: HoldingFlow | null; currency: string; onClose: () => void }) {
  const remove = useRemoveHoldingFlow(profileCode);
  const toast = useToast();
  const linked = !!flow?.txn_code;
  return (
    <ConfirmDialog
      open={!!flow}
      onOpenChange={(o) => {
        if (!o) {
          onClose();
          remove.reset();
        }
      }}
      title={linked ? "Unlink this payment?" : "Remove this entry?"}
      confirmLabel={linked ? "Unlink" : "Remove"}
      pending={remove.isPending}
      error={remove.error ? new Error(holdingErrorMessage(remove.error)) : null}
      onConfirm={() =>
        flow &&
        remove.mutate(flow.flow_code, {
          onSuccess: () => {
            toast({ title: linked ? "Payment unlinked" : "Entry removed", tone: "positive" });
            onClose();
          },
        })
      }
    >
      {flow && (
        <>
          {FLOW_KIND_LABEL[flow.kind] ?? flow.kind} of {formatMoney(flow.amount, { currency })} on {formatDate(flow.flow_date)}
          {linked
            ? ". The payment goes back to counting by its category, and the link rule won't link it again. You can still link it by hand from the transaction."
            : " stops counting in this holding's figures and returns."}
        </>
      )}
    </ConfirmDialog>
  );
}
