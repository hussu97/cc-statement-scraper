import { useMemo, useRef, useState, type FormEvent, type ReactNode } from "react";
import { useNavigate } from "@tanstack/react-router";
import { AlertTriangle, FileUp, Trash2 } from "lucide-react";
import { useCashPosition } from "@/data/cash";
import { useCreateNote, useExtractTermSheet } from "@/data/notes";
import { errorMessage } from "@/data/api";
import { bankAccountLabel } from "@/lib/cash-flow";
import { branchFormula, createNoteDraft, draftProblems, scheduleSummary, type DraftBranch, type DraftObservation, type DraftUnderlying, type InvestmentForm, type NoteDraft } from "@/lib/notes";
import { cn } from "@/lib/cn";
import { Dialog } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Field, Input, NativeSelect } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { FormError } from "@/components/cash/bank-account-dialogs";

/**
 * Add a structured note: upload its term sheet, review what was read (every field can be
 * corrected), then say what was bought and from which account.
 */
export function AddNoteDialog({ profileCode, open, onClose, fundingAccount }: { profileCode: string; open: boolean; onClose: () => void; fundingAccount?: string }) {
  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()} title="Add a structured note" description="From its term sheet (PDF). Nothing is saved until you confirm." className="max-w-4xl!">
      {open && <AddNote profileCode={profileCode} onDone={onClose} fundingAccount={fundingAccount} />}
    </Dialog>
  );
}

function AddNote({ profileCode, onDone, fundingAccount }: { profileCode: string; onDone: () => void; fundingAccount?: string }) {
  const extract = useExtractTermSheet(profileCode);
  const [draft, setDraft] = useState<NoteDraft | null>(null);
  const [warnings, setWarnings] = useState<string[]>([]);
  const input = useRef<HTMLInputElement>(null);

  const read = (file: File | undefined) => {
    if (!file) return;
    extract.mutate(file, {
      onSuccess: (r) => {
        setDraft(r.draft);
        setWarnings(r.warnings);
      },
    });
  };

  if (draft) return <Review profileCode={profileCode} initial={draft} warnings={warnings} onDone={onDone} fundingAccount={fundingAccount} />;

  return (
    <div className="flex flex-col gap-4">
      <button
        type="button"
        onClick={() => input.current?.click()}
        onDragOver={(e) => e.preventDefault()}
        onDrop={(e) => {
          e.preventDefault();
          read(e.dataTransfer.files[0]);
        }}
        disabled={extract.isPending}
        className="tap flex flex-col items-center gap-2 rounded-lg border border-dashed border-border-strong px-6 py-10 text-center hover:bg-surface-2/60 disabled:opacity-60"
      >
        <FileUp className="size-6 text-subtle" />
        <span className="text-sm font-medium text-ink">{extract.isPending ? "Reading the term sheet…" : "Choose or drop the term sheet"}</span>
        <span className="max-w-md text-[13px] text-muted">
          {extract.isPending
            ? "Claude is transcribing the coupons, autocall dates and payout. This takes about half a minute."
            : "The issuer's final terms: underlyings and initial levels, the observation schedule, and what is paid at maturity."}
        </span>
      </button>
      <input ref={input} type="file" accept="application/pdf,.pdf" hidden onChange={(e) => read(e.target.files?.[0])} />
      <FormError error={extract.isError ? errorMessage(extract.error) : null} />
    </div>
  );
}

function Review({ profileCode, initial, warnings, onDone, fundingAccount }: { profileCode: string; initial: NoteDraft; warnings: string[]; onDone: () => void; fundingAccount?: string }) {
  const create = useCreateNote(profileCode);
  const cash = useCashPosition(profileCode);
  const toast = useToast();
  const navigate = useNavigate();
  const [d, setD] = useState<NoteDraft>(initial);
  const t = d.terms;
  const accounts = useMemo(() => (cash.data?.accounts ?? []).filter((a) => a.currency === t.currency.toUpperCase()), [cash.data, t.currency]);
  const [inv, setInv] = useState<InvestmentForm>({
    invested_amount: "",
    purchase_price_pct: "",
    nominal: "",
    trade_date: initial.terms.issue_date ?? initial.terms.strike_date,
    funding_account_code: fundingAccount ?? "",
  });
  const [showSchedule, setShowSchedule] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fundingCode = inv.funding_account_code || (accounts.length === 1 ? (accounts[0]?.account_code ?? "") : "");

  const setTerms = (patch: Partial<NoteDraft["terms"]>) => setD((x) => ({ ...x, terms: { ...x.terms, ...patch } }));
  const setU = (i: number, patch: Partial<DraftUnderlying>) => setTerms({ underlyings: t.underlyings.map((u, j) => (j === i ? { ...u, ...patch } : u)) });
  const setO = (i: number, patch: Partial<DraftObservation>) => setTerms({ observations: t.observations.map((o, j) => (j === i ? { ...o, ...patch } : o)) });
  const setB = (i: number, patch: Partial<DraftBranch>) => setTerms({ payout: t.payout.map((b, j) => (j === i ? { ...b, ...patch } : b)) });

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const investment = { ...inv, funding_account_code: fundingCode };
    const problems = draftProblems(d, investment);
    if (problems.length > 0) {
      setError(problems.join(" "));
      return;
    }
    setError(null);
    create.mutate(createNoteDraft(d, investment, null), {
      onSuccess: ({ holdingCode, prices }) => {
        toast({
          title: "Note added",
          description: prices
            ? prices.failed.length > 0
              ? `${d.name}. No prices for ${prices.failed.length} share(s) yet: check their symbols.`
              : `${d.name}: prices are in, its status is up to date.`
            : `${d.name}. Prices will follow on tonight's run.`,
          tone: prices && prices.failed.length > 0 ? "neutral" : "positive",
        });
        onDone();
        void navigate({ to: "/wealth/investments/$holdingCode", params: { holdingCode } });
      },
      onError: (err) => setError(errorMessage(err)),
    });
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-5" noValidate>
      {warnings.length > 0 && (
        <div role="note" className="rounded-md border border-warn/40 bg-warn-soft px-4 py-3 text-[13px] text-ink-2">
          <p className="mb-1 flex items-center gap-1.5 font-medium text-warn">
            <AlertTriangle className="size-4" /> Check before saving
          </p>
          <ul className="list-disc space-y-0.5 pl-5">
            {warnings.map((w) => (
              <li key={w}>{w}</li>
            ))}
          </ul>
        </div>
      )}

      <Section title="The note">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="Name" className="sm:col-span-2" hint={t.product_name}>
            {(id, desc) => <Input id={id} aria-describedby={desc} maxLength={80} value={d.name} onChange={(e) => setD({ ...d, name: e.target.value })} />}
          </Field>
          <Text label="ISIN" value={t.isin ?? ""} onChange={(v) => setTerms({ isin: v })} />
          <Text label="Issuer" value={t.issuer ?? ""} onChange={(v) => setTerms({ issuer: v })} />
          <Text label="Currency" value={t.currency} onChange={(v) => setTerms({ currency: v.toUpperCase() })} />
          <Text label="Denomination" value={t.denomination} onChange={(v) => setTerms({ denomination: v })} numeric />
          <Text label="Issue price (%)" value={t.issue_price_pct} onChange={(v) => setTerms({ issue_price_pct: v })} numeric />
          <Text label="Strike date" value={t.strike_date} onChange={(v) => setTerms({ strike_date: v })} type="date" />
          <Text label="Final valuation" value={t.final_valuation_date} onChange={(v) => setTerms({ final_valuation_date: v })} type="date" />
          <Text label="Maturity" value={t.maturity_date} onChange={(v) => setTerms({ maturity_date: v })} type="date" />
        </div>
      </Section>

      <Section title="Underlying shares" hint="The price symbol is the ticker the daily closes come from (Yahoo Finance): AMZN, NESN.SW.">
        <Scroll>
          <table className="w-full min-w-[520px] text-[13px]">
            <thead className="text-left text-[11px] text-subtle uppercase">
              <tr>
                <th className="py-1 pr-2 font-medium">Share</th>
                <th className="py-1 pr-2 font-medium">Symbol</th>
                <th className="py-1 pr-2 font-medium">Initial level</th>
              </tr>
            </thead>
            <tbody>
              {t.underlyings.map((u, i) => (
                <tr key={i}>
                  <td className="py-1 pr-2">
                    <Input aria-label={`Share ${i + 1} name`} value={u.name} onChange={(e) => setU(i, { name: e.target.value })} />
                  </td>
                  <td className="py-1 pr-2">
                    <Input aria-label={`${u.name} symbol`} className={cn("uppercase", !u.symbol && "border-danger")} value={u.symbol} onChange={(e) => setU(i, { symbol: e.target.value })} />
                  </td>
                  <td className="py-1 pr-2">
                    <Input aria-label={`${u.name} initial level`} inputMode="decimal" className="tabular" value={u.initial_level} onChange={(e) => setU(i, { initial_level: e.target.value })} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Scroll>
      </Section>

      <Section title="Observation schedule" hint={scheduleSummary(t.observations)}>
        <Button size="sm" variant="ghost" onClick={() => setShowSchedule((s) => !s)}>
          {showSchedule ? "Hide the dates" : `Check all ${t.observations.length} dates`}
        </Button>
        {showSchedule && (
          <Scroll className="mt-2 max-h-80">
            <table className="w-full min-w-[760px] text-[13px]">
              <thead className="sticky top-0 bg-surface text-left text-[11px] text-subtle uppercase">
                <tr>
                  {["Observed", "Paid", "Coupon %", "Barrier %", "Memory", "Autocall at %", "Repays %", ""].map((h) => (
                    <th key={h} className="py-1 pr-2 font-medium">
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {t.observations.map((o, i) => (
                  <tr key={i}>
                    <td className="py-0.5 pr-2">
                      <Input aria-label="Observation date" type="date" value={o.obs_date} onChange={(e) => setO(i, { obs_date: e.target.value })} />
                    </td>
                    <td className="py-0.5 pr-2">
                      <Input aria-label="Payment date" type="date" value={o.pay_date} onChange={(e) => setO(i, { pay_date: e.target.value })} />
                    </td>
                    {(["coupon_rate_pct", "coupon_barrier_pct"] as const).map((k) => (
                      <td key={k} className="w-20 py-0.5 pr-2">
                        <Input aria-label={k} inputMode="decimal" className="tabular" value={o[k] ?? ""} onChange={(e) => setO(i, { [k]: e.target.value || null })} />
                      </td>
                    ))}
                    <td className="py-0.5 pr-2 text-center">
                      <input type="checkbox" aria-label="Memory coupon" checked={o.coupon_memory} onChange={(e) => setO(i, { coupon_memory: e.target.checked })} />
                    </td>
                    {(["autocall_trigger_pct", "autocall_amount_pct"] as const).map((k) => (
                      <td key={k} className="w-20 py-0.5 pr-2">
                        <Input aria-label={k} inputMode="decimal" className="tabular" value={o[k] ?? ""} onChange={(e) => setO(i, { [k]: e.target.value || null })} />
                      </td>
                    ))}
                    <td className="py-0.5">
                      <Button size="sm" variant="ghost" aria-label="Remove this date" icon={<Trash2 className="size-3.5" />} onClick={() => setTerms({ observations: t.observations.filter((_, j) => j !== i) })} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Scroll>
        )}
      </Section>

      <Section title="At maturity" hint="WP is the worst share's final level in % of its initial level. The highest row at or below WP pays; physical means shares of the worst share worth that much.">
        <Scroll>
          <table className="w-full min-w-[560px] text-[13px]">
            <thead className="text-left text-[11px] text-subtle uppercase">
              <tr>
                <th className="py-1 pr-2 font-medium">Worst from %</th>
                <th className="py-1 pr-2 font-medium">Pays % (fixed)</th>
                <th className="py-1 pr-2 font-medium">+ × WP</th>
                <th className="py-1 pr-2 font-medium">Settled</th>
                <th className="py-1 font-medium">Reads</th>
              </tr>
            </thead>
            <tbody>
              {t.payout.map((b, i) => (
                <tr key={i}>
                  <td className="w-24 py-1 pr-2">
                    <Input aria-label="From worst %" inputMode="decimal" className="tabular" value={b.min_worst_pct} onChange={(e) => setB(i, { min_worst_pct: e.target.value })} />
                  </td>
                  <td className="w-24 py-1 pr-2">
                    <Input aria-label="Fixed %" inputMode="decimal" className="tabular" value={b.intercept_pct} onChange={(e) => setB(i, { intercept_pct: e.target.value })} />
                  </td>
                  <td className="w-24 py-1 pr-2">
                    <Input aria-label="Times WP" inputMode="decimal" className="tabular" value={b.slope} onChange={(e) => setB(i, { slope: e.target.value })} />
                  </td>
                  <td className="w-28 py-1 pr-2">
                    <NativeSelect aria-label="Settlement" value={b.settlement} onChange={(e) => setB(i, { settlement: e.target.value })}>
                      <option value="cash">Cash</option>
                      <option value="physical">Shares</option>
                    </NativeSelect>
                  </td>
                  <td className="py-1 text-ink-2">
                    {branchFormula(b)}
                    {b.description && <span className="block text-[11px] text-muted">{b.description}</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Scroll>
      </Section>

      <Section title="What you bought">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label={`Amount invested (${t.currency || "—"})`} hint="What left your cash for this note.">
            {(id, desc) => <Input id={id} aria-describedby={desc} inputMode="decimal" className="tabular" placeholder="50000" value={inv.invested_amount} onChange={(e) => setInv({ ...inv, invested_amount: e.target.value })} />}
          </Field>
          <Field label="Price paid (%)" hint={`Defaults to the issue price, ${t.issue_price_pct || "—"}%.`}>
            {(id, desc) => <Input id={id} aria-describedby={desc} inputMode="decimal" className="tabular" placeholder={t.issue_price_pct} value={inv.purchase_price_pct} onChange={(e) => setInv({ ...inv, purchase_price_pct: e.target.value })} />}
          </Field>
          <Field label="Nominal (optional)" hint="The face amount on your statement. Left empty: amount ÷ price.">
            {(id, desc) => <Input id={id} aria-describedby={desc} inputMode="decimal" className="tabular" value={inv.nominal} onChange={(e) => setInv({ ...inv, nominal: e.target.value })} />}
          </Field>
          <Text label="Trade date" value={inv.trade_date} onChange={(v) => setInv({ ...inv, trade_date: v })} type="date" />
          <Field
            label="Paid from"
            className="sm:col-span-2"
            hint={accounts.length === 0 ? `No ${t.currency} bank account yet: add your Swissquote account under Accounts to track its cash. The note is saved without one.` : "Coupons and redemptions are paid back into it on their payment dates."}
          >
            {(id, desc) => (
              <NativeSelect id={id} aria-describedby={desc} value={fundingCode} onChange={(e) => setInv({ ...inv, funding_account_code: e.target.value })} disabled={accounts.length === 0}>
                <option value="">Not tracked</option>
                {accounts.map((a) => (
                  <option key={a.account_code} value={a.account_code}>
                    {a.bank_code} · {bankAccountLabel(a)} ({a.currency})
                  </option>
                ))}
              </NativeSelect>
            )}
          </Field>
        </div>
      </Section>

      <FormError error={error} />
      <div className="flex flex-wrap justify-end gap-2 border-t border-border pt-3">
        <Button onClick={onDone}>Cancel</Button>
        <Button type="submit" variant="primary" loading={create.isPending}>
          Save note
        </Button>
      </div>
    </form>
  );
}

function Section({ title, hint, children }: { title: string; hint?: string; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-2">
      <div>
        <h3 className="text-[13px] font-semibold text-ink">{title}</h3>
        {hint && <p className="text-[12px] text-muted">{hint}</p>}
      </div>
      {children}
    </section>
  );
}

function Scroll({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("-mx-1 overflow-auto px-1", className)}>{children}</div>;
}

function Text({ label, value, onChange, numeric, type }: { label: string; value: string; onChange: (v: string) => void; numeric?: boolean; type?: "date" }) {
  return (
    <Field label={label}>
      {(id) => <Input id={id} type={type} inputMode={numeric ? "decimal" : undefined} className={numeric ? "tabular" : undefined} value={value} onChange={(e) => onChange(e.target.value)} />}
    </Field>
  );
}
