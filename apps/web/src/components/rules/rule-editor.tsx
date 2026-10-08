import { useMemo, useState } from "react";
import { ChevronRight, Loader2 } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useFilterMeta } from "@/data/overview";
import {
  DIRECTIONS,
  MATCH_TYPES,
  TXN_KINDS,
  orderCategories,
  previewArgs,
  useCategories,
  useRulePreview,
  useSaveRule,
  validateRule,
  type RuleConditions,
  type RuleDraft,
} from "@/data/rules";
import { errorMessage } from "@/data/api";
import { useDebouncedValue } from "@/lib/hooks";
import { formatCount, formatMoney } from "@/lib/money";
import { formatDate } from "@/lib/dates";
import { cn } from "@/lib/cn";
import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/dialog";
import { Field, Input, NativeSelect } from "@/components/ui/input";
import { ANY, Select } from "@/components/ui/select";
import { Switch } from "@/components/ui/primitives";
import { Dot } from "@/components/ui/display";
import { useToast } from "@/components/ui/toast";

const MATCH_HINT: Record<string, string> = {
  contains: "Anywhere in the description. Case doesn't matter.",
  prefix: "The description starts with this text.",
  exact: "The whole description, and nothing else.",
  regex: "A regular expression, for advanced patterns.",
};

export function RuleEditor({ initial, onClose }: { initial: RuleDraft; onClose: () => void }) {
  const { profile_code: profileCode } = useActiveProfile();
  const categories = useCategories(profileCode);
  const meta = useFilterMeta(profileCode);
  const save = useSaveRule(profileCode);
  const toast = useToast();
  const [d, setD] = useState<RuleDraft>(initial);
  const [touched, setTouched] = useState(false);
  const hasConditions = Object.values(initial.conditions).some((v) => v?.trim());
  const [showConditions, setShowConditions] = useState(hasConditions);

  const set = (patch: Partial<RuleDraft>) => setD((x) => ({ ...x, ...patch }));
  const setCond = (patch: Partial<RuleConditions>) => setD((x) => ({ ...x, conditions: { ...x.conditions, ...patch } }));
  const error = validateRule(d);

  const ordered = useMemo(
    () => orderCategories((categories.data ?? []).filter((c) => !c.archived_at || c.category_code === d.category_code)),
    [categories.data, d.category_code],
  );
  const catByCode = useMemo(() => new Map((categories.data ?? []).map((c) => [c.category_code, c])), [categories.data]);
  const selected = catByCode.get(d.category_code);

  const live = useMemo(() => previewArgs(d), [d]);
  const args = useDebouncedValue(live, 400);

  const submit = () => {
    setTouched(true);
    if (error) return;
    save.mutate(d, {
      onSuccess: () => {
        toast({ title: d.rule_code ? "Rule saved" : "Rule created", description: "Matching transactions are being updated.", tone: "positive" });
        onClose();
      },
    });
  };

  return (
    <Sheet
      open
      onOpenChange={(o) => !o && onClose()}
      title={d.rule_code ? "Edit rule" : "New rule"}
      description="Rules decide a category from the description. Your own choices always win."
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" loading={save.isPending} onClick={submit}>
            {d.rule_code ? "Save rule" : "Create rule"}
          </Button>
        </>
      }
    >
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <div className="grid grid-cols-[minmax(0,2fr)_minmax(0,3fr)] gap-3">
          <Field label="When the description">
            {() => (
              <Select
                ariaLabel="Match type"
                value={d.match_type}
                onValueChange={(v) => set({ match_type: v })}
                options={MATCH_TYPES.map((m) => ({ value: m.value, label: m.label.toLowerCase() }))}
                className="w-full"
              />
            )}
          </Field>
          <Field label="Text" error={touched && !d.pattern.trim() ? "Enter text to match." : null}>
            {(id, desc) => (
              <Input
                id={id}
                aria-describedby={desc}
                aria-invalid={touched && !d.pattern.trim()}
                value={d.pattern}
                onChange={(e) => set({ pattern: e.target.value })}
                placeholder={d.match_type === "regex" ? "^UBER\\s*\\*?TRIP" : "COFFEE"}
                className={cn(d.match_type !== "regex" && "uppercase placeholder:normal-case", "font-mono text-[13px]")}
                autoFocus={!d.pattern}
                spellCheck={false}
              />
            )}
          </Field>
        </div>
        <p className="-mt-2 text-xs text-muted">{MATCH_HINT[d.match_type]}</p>

        <Field label="Set category to" error={touched && !d.category_code ? "Choose a category." : null}>
          {(id, desc) => (
            <div className="relative">
              <span className="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2">
                <Dot token={selected?.color_token ?? null} />
              </span>
              <NativeSelect
                id={id}
                aria-describedby={desc}
                aria-invalid={touched && !d.category_code}
                value={d.category_code}
                onChange={(e) => set({ category_code: e.target.value })}
                className="pl-7"
                disabled={categories.isLoading}
              >
                <option value="">{categories.isLoading ? "Loading categories…" : "Choose a category"}</option>
                {ordered.map((c) => (
                  <option key={c.category_code} value={c.category_code}>
                    {c.depth ? `   ${c.name}` : c.name}
                  </option>
                ))}
              </NativeSelect>
            </div>
          )}
        </Field>

        <div className="grid grid-cols-[minmax(0,3fr)_minmax(0,2fr)] gap-3">
          <Field label="Name" hint="Optional, for your reference.">
            {(id, desc) => <Input id={id} aria-describedby={desc} value={d.name} onChange={(e) => set({ name: e.target.value })} maxLength={80} />}
          </Field>
          <Field label="Priority" hint="Lower runs first.">
            {(id, desc) => (
              <Input
                id={id}
                aria-describedby={desc}
                type="number"
                inputMode="numeric"
                min={0}
                max={10000}
                value={Number.isFinite(d.priority) ? d.priority : ""}
                onChange={(e) => set({ priority: e.target.value === "" ? 100 : Math.trunc(Number(e.target.value)) })}
                className="tabular"
              />
            )}
          </Field>
        </div>

        <div className="rounded-md border border-border">
          <button
            type="button"
            onClick={() => setShowConditions((v) => !v)}
            aria-expanded={showConditions}
            className="flex w-full items-center gap-2 px-3 py-2.5 text-left text-[13px] font-medium text-ink-2 hover:text-ink"
          >
            <ChevronRight className={cn("size-3.5 transition-transform", showConditions && "rotate-90")} aria-hidden />
            Only when…
            <span className="font-normal text-subtle">amount, bank, currency, type</span>
          </button>
          {showConditions && (
            <div className="grid grid-cols-2 gap-3 border-t border-border p-3">
              <Field label="Amount from (AED)">
                {(id) => (
                  <Input id={id} inputMode="decimal" placeholder="0.00" value={d.conditions.amount_min ?? ""} onChange={(e) => setCond({ amount_min: e.target.value })} className="tabular" />
                )}
              </Field>
              <Field label="Amount to (AED)">
                {(id) => (
                  <Input id={id} inputMode="decimal" placeholder="Any" value={d.conditions.amount_max ?? ""} onChange={(e) => setCond({ amount_max: e.target.value })} className="tabular" />
                )}
              </Field>
              <Field label="Bank">
                {() => (
                  <Select
                    ariaLabel="Bank"
                    value={d.conditions.bank_code || ANY}
                    onValueChange={(v) => setCond({ bank_code: v === ANY ? "" : v })}
                    options={[{ value: ANY, label: "Any bank" }, ...(meta.data?.banks ?? []).map((b) => ({ value: b.bank_code, label: b.name }))]}
                    className="w-full"
                  />
                )}
              </Field>
              <Field label="Currency">
                {(id) => (
                  <Input
                    id={id}
                    placeholder="Any, e.g. USD"
                    maxLength={3}
                    value={d.conditions.currency ?? ""}
                    onChange={(e) => setCond({ currency: e.target.value.toUpperCase() })}
                    className="uppercase placeholder:normal-case"
                  />
                )}
              </Field>
              <Field label="Type">
                {() => (
                  <Select
                    ariaLabel="Transaction type"
                    value={d.conditions.kind || ANY}
                    onValueChange={(v) => setCond({ kind: v === ANY ? "" : v })}
                    options={[{ value: ANY, label: "Any type" }, ...TXN_KINDS.map((k) => ({ value: k.value, label: k.label }))]}
                    className="w-full"
                  />
                )}
              </Field>
              <Field label="Direction">
                {() => (
                  <Select
                    ariaLabel="Direction"
                    value={d.conditions.direction || ANY}
                    onValueChange={(v) => setCond({ direction: v === ANY ? "" : v })}
                    options={[{ value: ANY, label: "Either" }, ...DIRECTIONS.map((k) => ({ value: k.value, label: k.label }))]}
                    className="w-full"
                  />
                )}
              </Field>
            </div>
          )}
        </div>

        <label className="flex items-center justify-between gap-3 text-sm text-ink">
          <span>
            Active
            <span className="block text-xs text-muted">Inactive rules are kept but don't categorise anything.</span>
          </span>
          <Switch checked={d.active} onCheckedChange={(v) => set({ active: v })} aria-label="Active" />
        </label>

        <RulePreview
          profileCode={profileCode}
          args={live ? args : null}
          pending={!!live && live !== args}
          draftError={error}
          catName={(c) => catByCode.get(c ?? "")?.name ?? "Uncategorised"}
          catToken={(c) => catByCode.get(c ?? "")?.color_token ?? null}
          targetCode={d.category_code}
          target={selected?.name ?? ""}
        />

        {touched && error && d.pattern.trim() && d.category_code ? <p className="text-[13px] text-danger">{error}</p> : null}
        {save.error ? <p className="text-[13px] text-danger">{errorMessage(save.error)}</p> : null}
        <button type="submit" hidden />
      </form>
    </Sheet>
  );
}

function RulePreview({
  profileCode,
  args,
  pending,
  draftError,
  catName,
  catToken,
  targetCode,
  target,
}: {
  profileCode: string;
  args: ReturnType<typeof previewArgs>;
  pending: boolean;
  draftError: string | null;
  catName: (code: string | null) => string;
  catToken: (code: string | null) => string | null;
  targetCode: string;
  target: string;
}) {
  const preview = useRulePreview(profileCode, args);
  const busy = pending || preview.isFetching;
  let body;
  if (draftError || !args) {
    body = <p className="text-[13px] text-muted">{draftError && draftError !== "Choose a category." && draftError !== "Enter text to match." ? draftError : "Enter text and a category to see what this rule would change."}</p>;
  } else if (preview.isError) {
    body = <p className="text-[13px] text-danger">{/regular expression|regex/i.test(errorMessage(preview.error)) ? "That regular expression isn't valid." : `Couldn't preview: ${errorMessage(preview.error)}`}</p>;
  } else if (!preview.data) {
    body = <p className="text-[13px] text-muted">Checking your transactions…</p>;
  } else {
    const p = preview.data;
    const matched = p.matched >= 1000 ? "1,000+" : formatCount(p.matched);
    body = (
      <>
        <p className="text-sm text-ink">
          {p.matched === 0 ? (
            "No transactions match yet. It will apply to new ones."
          ) : (
            <>
              Would change <span className="font-semibold tabular">{formatCount(p.would_change)}</span> of <span className="tabular">{matched}</span> matching{" "}
              {p.matched === 1 ? "transaction" : "transactions"}.
            </>
          )}
        </p>
        {p.matched > p.would_change && p.matched > 0 && (
          <p className="mt-1 text-xs text-muted">
            The rest are already {target ? `in ${target}` : "set"}, set by you, or caught by a rule with a lower priority number.
            {p.would_change === 0 && p.sample.some((x) => x.current_category_code !== targetCode) && " Lower this rule's priority to take over."}
          </p>
        )}
        {p.sample.length > 0 && <h4 className="mt-3 text-[12px] text-muted">Recent matches and their category now</h4>}
        {p.sample.length > 0 && (
          <ul className="mt-1.5 divide-y divide-border rounded-md border border-border bg-surface">
            {p.sample.slice(0, 8).map((s) => (
              <li key={s.txn_code} className="flex items-center gap-3 px-3 py-2">
                <div className="min-w-0 flex-1">
                  <p className="truncate font-mono text-[12px] text-ink">{s.description}</p>
                  <p className="mt-0.5 flex items-center gap-1 text-[11px] text-muted">
                    {formatDate(s.txn_date, "short")} · <Dot token={catToken(s.current_category_code)} className="size-1.5" /> {catName(s.current_category_code)}
                    
                  </p>
                </div>
                <span className="text-[12px] text-ink-2 tabular">{formatMoney(s.amount_aed)}</span>
              </li>
            ))}
          </ul>
        )}
      </>
    );
  }
  return (
    <section aria-live="polite" className="rounded-md bg-surface-2 p-3">
      <h3 className="mb-1.5 flex items-center gap-2 text-[11px] font-medium tracking-[0.08em] text-subtle uppercase">
        Preview
        {busy && args && <Loader2 className="size-3 animate-spin" aria-label="Updating preview" />}
      </h3>
      {body}
    </section>
  );
}
