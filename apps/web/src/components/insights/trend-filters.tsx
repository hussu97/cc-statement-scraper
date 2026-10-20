import { useMemo, useState } from "react";
import { ChevronDown, X } from "lucide-react";
import type { FilterMeta } from "@/data/overview";
import { toggleCode, type Instrument, type TrendFilters } from "@/lib/trend-filters";
import { cn } from "@/lib/cn";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dot } from "@/components/ui/display";
import { Checkbox, Popover, PopoverContent, PopoverTrigger } from "@/components/ui/primitives";
import { Segmented } from "@/components/ui/segmented";
import { BankLogo } from "@/components/bank-logo";
import { SearchBox } from "@/components/activity/filters";
import { trendFilterChips, trendFilterOptions, withoutChip, type TrendFilterKind, type TrendFilterOption } from "./trend-filter-options";

const PICKERS: { kind: TrendFilterKind; label: string }[] = [
  { kind: "categories", label: "Categories" },
  { kind: "banks", label: "Banks" },
  { kind: "cards", label: "Cards" },
];

/**
 * Filter row for "Spending over time": merchant search, multi-select pickers
 * for categories, banks and cards, and the active filters as removable chips.
 */
export function TrendFilterBar({ filters, meta, onChange }: { filters: TrendFilters; meta: FilterMeta | undefined; onChange: (f: TrendFilters) => void }) {
  const options = useMemo(() => trendFilterOptions(meta), [meta]);
  const chips = trendFilterChips(filters, options);
  return (
    <div className="flex flex-col gap-2 px-5 pb-3">
      <div className="flex flex-wrap items-center gap-2">
        <SearchBox
          value={filters.q}
          onChange={(q) => onChange({ ...filters, q })}
          label="Search merchant or description"
          className="basis-full sm:basis-auto sm:max-w-64"
        />
        {/* Phone: the three pickers share one row; the count moves to the chips below. */}
        <div className="grid w-full grid-cols-[1.3fr_1fr_1fr] gap-2 sm:flex sm:w-auto">
          {PICKERS.map((p) => (
            <MultiPicker
              key={p.kind}
              label={p.label}
              options={options[p.kind]}
              selected={filters[p.kind]}
              searchable={p.kind === "categories" && options.categories.length > 8}
              onToggle={(v) => onChange({ ...filters, [p.kind]: toggleCode(filters[p.kind], v) })}
              onClear={() => onChange({ ...filters, [p.kind]: [] })}
            />
          ))}
        </div>
        <Segmented<"both" | Instrument>
          ariaLabel="Card type"
          value={filters.instrument ?? "both"}
          onChange={(v) => onChange({ ...filters, instrument: v === "both" ? undefined : v })}
          options={[
            { value: "both", label: "All cards" },
            { value: "credit_card", label: "Credit" },
            { value: "debit_card", label: "Debit" },
          ]}
        />
      </div>
      {chips.length > 0 && (
        <ul className="flex flex-wrap items-center gap-1.5" aria-label="Active filters">
          {chips.map((c) => (
            <li key={`${c.kind}:${c.value}`}>
              <button
                type="button"
                onClick={() => onChange(withoutChip(filters, c))}
                aria-label={`Remove filter ${c.label}`}
                className="tap inline-flex h-7 max-w-56 items-center gap-1 rounded-pill border border-border bg-surface-2 pr-1.5 pl-2.5 text-[12px] text-ink-2 hover:border-border-strong hover:text-ink"
              >
                <span className="truncate">{c.label}</span>
                <X className="size-3 shrink-0" aria-hidden />
              </button>
            </li>
          ))}
          <li>
            <Button size="sm" variant="ghost" onClick={() => onChange({ categories: [], banks: [], cards: [] })}>
              Clear
            </Button>
          </li>
        </ul>
      )}
    </div>
  );
}

function MultiPicker({
  label,
  options,
  selected,
  searchable,
  onToggle,
  onClear,
}: {
  label: string;
  options: TrendFilterOption[];
  selected: string[];
  searchable: boolean;
  onToggle: (value: string) => void;
  onClear: () => void;
}) {
  const [find, setFind] = useState("");
  const needle = find.trim().toLowerCase();
  const shown = needle ? options.filter((o) => o.label.toLowerCase().includes(needle)) : options;
  const n = selected.length;
  return (
    <Popover onOpenChange={(open) => !open && setFind("")}>
      <PopoverTrigger asChild>
        <Button
          size="md"
          variant={n ? "primary" : "secondary"}
          className="min-w-0 justify-center gap-1 px-2 text-[13px] font-normal sm:gap-2 sm:px-4 sm:text-sm"
          aria-label={n ? `${label}, ${n} selected` : label}
        >
          <span className="truncate">{label}</span>
          {n > 0 && <span className="hidden sm:inline">({n})</span>}
          <ChevronDown className="hidden size-3.5 opacity-70 sm:block" aria-hidden />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-72 p-1.5">
        {searchable && (
          <Input value={find} onChange={(e) => setFind(e.target.value)} placeholder={`Find ${label.toLowerCase()}`} aria-label={`Find ${label.toLowerCase()}`} className="mb-1.5 h-8 text-[13px]" />
        )}
        <ul className="max-h-72 overflow-y-auto" aria-label={label}>
          {shown.map((o) => {
            const id = `tf-${o.value}`;
            return (
              <li key={o.value}>
                <label htmlFor={id} className={cn("flex min-h-9 cursor-pointer items-center gap-2 rounded-sm px-2 text-[13px] text-ink hover:bg-surface-2", o.depth ? "pl-7" : "")}>
                  <Checkbox id={id} checked={selected.includes(o.value)} onCheckedChange={() => onToggle(o.value)} />
                  {o.bankCode && <BankLogo bankCode={o.bankCode} size="xs" decorative />}
                  {o.colorToken !== undefined && <Dot token={o.colorToken} />}
                  <span className="min-w-0 flex-1 truncate">{o.label}</span>
                  {o.hint && <span className="shrink-0 text-[11px] text-muted">{o.hint}</span>}
                </label>
              </li>
            );
          })}
          {shown.length === 0 && <li className="px-2 py-2 text-[13px] text-muted">{options.length ? "No matches." : `No ${label.toLowerCase()} yet.`}</li>}
        </ul>
        {n > 0 && (
          <div className="mt-1 border-t border-border pt-1">
            <Button size="sm" variant="ghost" onClick={onClear}>
              Clear {label.toLowerCase()}
            </Button>
          </div>
        )}
      </PopoverContent>
    </Popover>
  );
}
