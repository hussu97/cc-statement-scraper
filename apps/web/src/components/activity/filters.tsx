import { useEffect, useRef, useState, type ReactNode } from "react";
import { Search, SlidersHorizontal, X } from "lucide-react";
import { activeFilterCount, syncSearchText, UNCATEGORIZED, type ActivitySearch } from "@/lib/activity-filters";
import { matchPreset, presetRange, RANGE_PRESETS, formatDate } from "@/lib/dates";
import { useDebouncedValue } from "@/lib/hooks";
import { accountLabel, type FilterMeta } from "@/data/overview";
import { orderCategories } from "@/data/rules";
import { Input } from "@/components/ui/input";
import { ANY, Select } from "@/components/ui/select";
import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/dialog";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/primitives";
import { BankLogo } from "@/components/bank-logo";
import { cn } from "@/lib/cn";

type Patch = (p: Partial<ActivitySearch>) => void;

/** Debounced search box: writes `?q=` 350ms after typing stops, and follows `?q=` when it changes elsewhere. */
export function SearchBox({
  value,
  onChange,
  label = "Search description or merchant",
  className,
}: {
  value: string | undefined;
  onChange: (v: string | undefined) => void;
  label?: string;
  className?: string;
}) {
  const [text, setText] = useState(value ?? "");
  const written = useRef<string | undefined>(value);
  const debounced = useDebouncedValue(text, 350);
  useEffect(() => {
    const next = debounced.trim() || undefined;
    if (next !== written.current) {
      written.current = next;
      onChange(next);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [debounced]);
  // "Clear filters" / Back changed ?q= underneath us: show it (WEB-08).
  useEffect(() => {
    const sync = syncSearchText(value, written.current);
    if (sync !== null) {
      written.current = value;
      setText(sync);
    }
  }, [value]);
  return (
    <div className={cn("relative min-w-0 flex-1 sm:max-w-80", className)}>
      <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-subtle" aria-hidden />
      <Input value={text} onChange={(e) => setText(e.target.value)} placeholder={label} aria-label={label} className="pl-9" />
      {text && (
        <button type="button" aria-label="Clear search" onClick={() => setText("")} className="absolute top-1/2 right-0.5 flex size-9 -translate-y-1/2 items-center justify-center rounded-sm text-subtle hover:text-ink">
          <X className="size-3.5" />
        </button>
      )}
    </div>
  );
}

function DateFilter({ search, patch }: { search: ActivitySearch; patch: Patch }) {
  const preset = search.from && search.to ? matchPreset({ from: search.from, to: search.to }) : null;
  const label = !search.from && !search.to
    ? "Any date"
    : preset
      ? RANGE_PRESETS.find((p) => p.value === preset)?.label
      : `${search.from ? formatDate(search.from, "short") : "…"} – ${search.to ? formatDate(search.to, "short") : "…"}`;
  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button size="md" variant="secondary" className="justify-between font-normal">{label}</Button>
      </PopoverTrigger>
      <PopoverContent className="w-72">
        <div className="grid grid-cols-2 gap-1.5">
          {RANGE_PRESETS.map((p) => (
            <Button key={p.value} size="sm" variant={preset === p.value ? "primary" : "secondary"} onClick={() => patch(presetRange(p.value))}>
              {p.label}
            </Button>
          ))}
        </div>
        <div className="mt-3 grid grid-cols-2 gap-2 border-t border-border pt-3">
          <label className="flex flex-col gap-1 text-[12px] text-muted">
            From
            <Input type="date" value={search.from ?? ""} onChange={(e) => patch({ from: e.target.value || undefined })} className="h-8 px-2 text-[13px]" />
          </label>
          <label className="flex flex-col gap-1 text-[12px] text-muted">
            To
            <Input type="date" value={search.to ?? ""} onChange={(e) => patch({ to: e.target.value || undefined })} className="h-8 px-2 text-[13px]" />
          </label>
        </div>
        {(search.from || search.to) && (
          <Button size="sm" variant="ghost" className="mt-2" onClick={() => patch({ from: undefined, to: undefined })}>
            Any date
          </Button>
        )}
      </PopoverContent>
    </Popover>
  );
}

function FilterFields({ search, patch, meta }: { search: ActivitySearch; patch: Patch; meta: FilterMeta | undefined }) {
  const v = (x: string | undefined) => x ?? ANY;
  const u = (x: string) => (x === ANY ? undefined : x);
  const cards = (meta?.cards ?? []).filter((c) => !search.account || c.account_code === search.account);
  const cats = orderCategories((meta?.categories ?? []).map((c) => ({ ...c, sort_order: 0 })));
  const fields: ReactNode[] = [
    <DateFilter key="date" search={search} patch={patch} />,
    <Select
      key="account"
      ariaLabel="Account"
      value={v(search.account)}
      onValueChange={(x) => patch({ account: u(x), card: undefined })}
      options={[{ value: ANY, label: "All accounts" }, ...(meta?.accounts ?? []).map((a) => ({
          value: a.account_code,
          label: (
            <span className="inline-flex min-w-0 items-center gap-1.5">
              <BankLogo bankCode={a.bank_code} size="xs" decorative />
              <span className="truncate">{accountLabel(a)}</span>
            </span>
          ),
        }))]}
    />,
    <Select
      key="card"
      ariaLabel="Card"
      value={v(search.card)}
      onValueChange={(x) => patch({ card: u(x) })}
      options={[{ value: ANY, label: "All cards" }, ...cards.map((c) => ({
          value: c.card_code,
          label: (
            <span className="inline-flex min-w-0 items-center gap-1.5">
              <BankLogo bankCode={c.bank_code} size="xs" decorative />
              <span className="truncate">{`${c.bank_code} •${c.last4}${c.is_supplementary ? " (supp.)" : ""}`}</span>
            </span>
          ),
        }))]}
    />,
    <Select
      key="category"
      ariaLabel="Category"
      value={v(search.category)}
      onValueChange={(x) => patch({ category: u(x) })}
      options={[
        { value: ANY, label: "All categories" },
        { value: UNCATEGORIZED, label: "Uncategorised" },
        ...cats.map((c) => ({ value: c.category_code, label: `${c.depth ? "  ↳ " : ""}${c.name}${c.archived ? " (archived)" : ""}` })),
      ]}
    />,
    <Select
      key="status"
      ariaLabel="Status"
      value={v(search.status)}
      onValueChange={(x) => patch({ status: u(x) as ActivitySearch["status"] })}
      options={[
        { value: ANY, label: "Any status" },
        { value: "void", label: "Void" },
        { value: "orphaned", label: "Orphaned" },
      ]}
    />,
    <Select
      key="source"
      ariaLabel="Source"
      value={v(search.source)}
      onValueChange={(x) => patch({ source: u(x) as ActivitySearch["source"] })}
      options={[
        { value: ANY, label: "Any source" },
        { value: "sms", label: "SMS only" },
        { value: "statement", label: "Statement only" },
        { value: "both", label: "SMS + statement" },
      ]}
    />,
  ];
  return <>{fields}</>;
}

export function ActivityFilters({ search, patch, meta, onClear }: { search: ActivitySearch; patch: Patch; meta: FilterMeta | undefined; onClear: () => void }) {
  const [sheet, setSheet] = useState(false);
  const n = activeFilterCount(search) - (search.q ? 1 : 0);
  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <SearchBox value={search.q} onChange={(q) => patch({ q })} />
        <Button className="lg:hidden" icon={<SlidersHorizontal className="size-4" />} onClick={() => setSheet(true)}>
          Filters{n ? ` (${n})` : ""}
        </Button>
        {activeFilterCount(search) > 0 && (
          <Button variant="ghost" onClick={onClear} className="hidden lg:inline-flex">
            Clear filters
          </Button>
        )}
      </div>
      <div className="hidden flex-wrap gap-2 lg:flex [&>*]:min-w-36">
        <FilterFields search={search} patch={patch} meta={meta} />
      </div>
      <Sheet
        open={sheet}
        onOpenChange={setSheet}
        title="Filters"
        footer={
          <>
            <Button variant="ghost" onClick={onClear}>Clear all</Button>
            <Button variant="primary" onClick={() => setSheet(false)}>Show results</Button>
          </>
        }
      >
        <div className="flex flex-col gap-3 [&>*]:w-full">
          <FilterFields search={search} patch={patch} meta={meta} />
        </div>
      </Sheet>
    </div>
  );
}
