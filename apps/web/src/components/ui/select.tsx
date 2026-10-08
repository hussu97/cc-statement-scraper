import { Select as S } from "radix-ui";
import { Check, ChevronDown } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

export interface SelectOption {
  value: string;
  label: ReactNode;
  disabled?: boolean;
}

/** Radix Select can't hold "" — use this sentinel for "any". */
export const ANY = "__any";

export function Select({
  value,
  onValueChange,
  options,
  placeholder,
  className,
  ariaLabel,
  size = "md",
  disabled,
}: {
  value: string | undefined;
  onValueChange: (v: string) => void;
  options: SelectOption[];
  placeholder?: string;
  className?: string;
  ariaLabel?: string;
  size?: "sm" | "md";
  disabled?: boolean;
}) {
  return (
    <S.Root value={value} onValueChange={onValueChange} disabled={disabled}>
      <S.Trigger
        aria-label={ariaLabel}
        className={cn(
          "inline-flex items-center justify-between gap-2 rounded-md border border-border bg-surface px-3 text-left text-sm text-ink transition-colors hover:border-border-strong focus:border-accent focus:outline-none data-[placeholder]:text-subtle disabled:opacity-60",
          size === "sm" ? "h-8 text-[13px]" : "h-10",
          className,
        )}
      >
        <span className="truncate">
          <S.Value placeholder={placeholder} />
        </span>
        <S.Icon>
          <ChevronDown className="size-4 text-muted" aria-hidden />
        </S.Icon>
      </S.Trigger>
      <S.Portal>
        <S.Content
          position="popper"
          sideOffset={4}
          className="z-50 max-h-[min(360px,var(--radix-select-content-available-height))] min-w-[var(--radix-select-trigger-width)] overflow-hidden rounded-md border border-border bg-surface shadow-[0_8px_24px_-12px_var(--color-border-strong)] animate-fade-in"
        >
          <S.Viewport className="p-1">
            {options.map((o) => (
              <S.Item
                key={o.value}
                value={o.value}
                disabled={o.disabled}
                className="relative flex h-8 cursor-pointer items-center rounded-sm pr-2 pl-7 text-[13px] text-ink outline-none select-none data-[disabled]:opacity-50 data-[highlighted]:bg-surface-2"
              >
                <S.ItemIndicator className="absolute left-2">
                  <Check className="size-3.5 text-accent" aria-hidden />
                </S.ItemIndicator>
                <S.ItemText>{o.label}</S.ItemText>
              </S.Item>
            ))}
          </S.Viewport>
        </S.Content>
      </S.Portal>
    </S.Root>
  );
}
