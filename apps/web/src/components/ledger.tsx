import { useMemo, useState, type ReactNode } from "react";
import { Check, ChevronDown, MessageSquareText, FileText, Layers, CircleDashed, Search, Tag } from "lucide-react";
import { cn } from "@/lib/cn";
import { formatMoney, formatTxnAmount, type MoneyInput } from "@/lib/money";
import { Popover, PopoverContent, PopoverTrigger, Checkbox, Tooltip } from "./ui/primitives";
import { Badge, Dot, type Tone } from "./ui/display";
import { orderCategories } from "@/data/rules";

export function Money({ value, currency = "AED", direction, className, signed, compact }: { value: MoneyInput; currency?: string; direction?: string | null; className?: string; signed?: boolean; compact?: boolean }) {
  const text = direction ? formatTxnAmount(value, direction, currency) : formatMoney(value, { currency, signed, compact });
  return <span className={cn("tabular whitespace-nowrap", direction === "credit" && "text-positive", className)}>{text}</span>;
}

/** Hero figure: small currency code + large Fraunces numerals. */
export function HeroAmount({ value, currency = "AED", className }: { value: MoneyInput; currency?: string; className?: string }) {
  const figure = formatMoney(value, { currency, bare: true });
  return (
    <span className={cn("inline-flex items-baseline gap-2", className)}>
      <span className="text-sm font-medium tracking-wide text-muted">{currency}</span>
      <span className="display-num text-[44px] leading-none text-ink md:text-[56px]">{figure}</span>
    </span>
  );
}

const STATUS_TONE: Record<string, Tone> = { pending: "warn", posted: "neutral", void: "neutral", orphaned: "danger" };
export function StatusBadge({ status }: { status: string | null | undefined }) {
  if (!status || status === "posted") return null;
  return (
    <Badge tone={STATUS_TONE[status] ?? "neutral"} className={status === "void" ? "line-through" : undefined}>
      {status}
    </Badge>
  );
}

const EVIDENCE: Record<string, { label: string; icon: ReactNode; tip: string }> = {
  both: { label: "SMS + statement", icon: <Layers className="size-3" />, tip: "Seen by SMS and confirmed by a statement" },
  sms: { label: "SMS", icon: <MessageSquareText className="size-3" />, tip: "From a bank SMS; not on a statement yet" },
  statement: { label: "Statement", icon: <FileText className="size-3" />, tip: "From a statement only" },
  orphaned: { label: "No evidence", icon: <CircleDashed className="size-3" />, tip: "Its evidence was removed" },
  none: { label: "—", icon: null, tip: "" },
};

export function EvidenceBadge({ kind, compact }: { kind: string; compact?: boolean }) {
  const e = EVIDENCE[kind] ?? EVIDENCE.none!;
  if (kind === "none") return null;
  return (
    <Tooltip content={e.tip}>
      <span className="inline-flex items-center gap-1 text-[11px] text-muted" aria-label={e.tip}>
        {e.icon}
        {!compact && e.label}
      </span>
    </Tooltip>
  );
}

export interface PickerCategory {
  category_code: string;
  name: string;
  color_token: string | null;
  parent_code: string | null;
  kind?: string;
  archived?: boolean;
  sort_order?: number;
}

/** Category chip that opens a searchable picker. */
export function CategoryPicker({
  categories,
  value,
  label,
  colorToken,
  onSelect,
  allowApplyToMerchant,
  disabled,
  source,
  triggerClassName,
}: {
  categories: PickerCategory[];
  value: string | null | undefined;
  label?: string | null;
  colorToken?: string | null;
  onSelect: (code: string | null, applyToMerchant: boolean) => void;
  allowApplyToMerchant?: boolean;
  disabled?: boolean;
  source?: string | null;
  triggerClassName?: string;
}) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [toMerchant, setToMerchant] = useState(false);
  const list = useMemo(() => {
    const active = categories.filter((c) => !c.archived);
    const ordered = orderCategories(active.map((c) => ({ ...c, sort_order: c.sort_order ?? 100 })));
    const needle = q.trim().toLowerCase();
    return needle ? ordered.filter((c) => c.name.toLowerCase().includes(needle)) : ordered;
  }, [categories, q]);

  const pick = (code: string | null) => {
    onSelect(code, toMerchant);
    setOpen(false);
    setQ("");
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild disabled={disabled}>
        <button
          type="button"
          className={cn(
            "inline-flex max-w-full items-center gap-1.5 rounded-pill border border-transparent px-2 py-0.5 text-[12px] transition-colors hover:border-border hover:bg-surface-2 disabled:pointer-events-none",
            value ? "text-ink-2" : "text-subtle italic",
            triggerClassName,
          )}
          aria-label={value ? `Category: ${label}. Change` : "Set category"}
        >
          {value ? <Dot token={colorToken} /> : <Tag className="size-3" aria-hidden />}
          <span className="truncate">{value ? label : "Uncategorised"}</span>
          {source === "suggested" && <span className="text-[10px] text-subtle not-italic">(suggested)</span>}
          {!disabled && <ChevronDown className="size-3 shrink-0 text-subtle" aria-hidden />}
        </button>
      </PopoverTrigger>
      <PopoverContent className="w-64 p-0">
        <div className="flex items-center gap-2 border-b border-border px-3">
          <Search className="size-3.5 text-subtle" aria-hidden />
          <input
            autoFocus
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Find a category"
            aria-label="Find a category"
            className="h-9 w-full bg-transparent text-[13px] text-ink outline-none placeholder:text-subtle"
            onKeyDown={(e) => {
              if (e.key === "Enter" && list[0]) pick(list[0].category_code);
            }}
          />
        </div>
        <ul role="listbox" className="max-h-64 overflow-y-auto p-1">
          {list.map((c) => (
            <li key={c.category_code}>
              <button
                type="button"
                role="option"
                aria-selected={c.category_code === value}
                onClick={() => pick(c.category_code)}
                className={cn("flex h-8 w-full items-center gap-2 rounded-sm px-2 text-left text-[13px] text-ink hover:bg-surface-2", c.depth && "pl-6")}
              >
                <Dot token={c.color_token} />
                <span className="flex-1 truncate">{c.name}</span>
                {c.category_code === value && <Check className="size-3.5 text-accent" aria-hidden />}
              </button>
            </li>
          ))}
          {list.length === 0 && <li className="px-2 py-3 text-center text-[13px] text-muted">No category matches “{q}”.</li>}
        </ul>
        <div className="flex flex-col gap-2 border-t border-border p-2">
          {allowApplyToMerchant && (
            <label className="flex cursor-pointer items-center gap-2 px-1 text-[12px] text-ink-2">
              <Checkbox checked={toMerchant} onCheckedChange={(v) => setToMerchant(v === true)} />
              Apply to every transaction from this merchant
            </label>
          )}
          {value && (
            <button type="button" onClick={() => pick(null)} className="h-7 rounded-sm px-1 text-left text-[12px] text-muted hover:text-ink">
              Clear my choice
            </button>
          )}
        </div>
      </PopoverContent>
    </Popover>
  );
}

export function BankMark({ bank, className }: { bank: string | null | undefined; className?: string }) {
  return (
    <span
      aria-hidden
      className={cn(
        "inline-flex size-8 shrink-0 items-center justify-center rounded-md border border-border bg-surface-2 text-[10px] font-semibold tracking-wide text-ink-2",
        className,
      )}
    >
      {(bank ?? "?").slice(0, 4)}
    </span>
  );
}
