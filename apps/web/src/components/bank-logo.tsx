import { useState } from "react";
import { bankFallbackText, bankInfo, useBanks } from "@/data/banks";
import { cn } from "@/lib/cn";

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string | undefined;

const SIZES = { xs: "size-4 rounded-[4px] p-px", sm: "size-5 rounded-[5px] p-px", md: "size-8 rounded-md p-1", lg: "size-10 rounded-md p-1.5" } as const;
const TEXT = { xs: "text-[6px]", sm: "text-[7px]", md: "text-[10px]", lg: "text-[11px]" } as const;
export type BankLogoSize = keyof typeof SIZES;

/**
 * A bank's mark on a light rounded chip (`.bank-chip`: the navy and purple
 * marks stay legible in dark mode). The accessible name is the bank's name;
 * with no logo, or when it fails to load, the short code shows instead.
 * `decorative` hides it from assistive tech when adjacent text names the bank.
 */
export function BankLogo({ bankCode, size = "md", decorative, className }: { bankCode: string | null | undefined; size?: BankLogoSize; decorative?: boolean; className?: string }) {
  const banks = useBanks();
  const { name, logoUrl } = bankInfo(banks.data, bankCode, SUPABASE_URL);
  const [failed, setFailed] = useState<string | null>(null);
  const showImage = !!logoUrl && failed !== logoUrl;
  const a11y = decorative ? { "aria-hidden": true as const } : { role: "img" as const, "aria-label": name, title: name };
  return (
    <span
      {...a11y}
      className={cn(
        "inline-flex shrink-0 items-center justify-center overflow-hidden border border-border",
        showImage ? "bank-chip" : "bg-surface-2",
        SIZES[size],
        className,
      )}
    >
      {showImage ? (
        <img src={logoUrl} alt="" decoding="async" draggable={false} onError={() => setFailed(logoUrl)} className="size-full object-contain" />
      ) : (
        <span className={cn("font-semibold tracking-wide text-ink-2 leading-none", TEXT[size])}>{bankFallbackText(bankCode)}</span>
      )}
    </span>
  );
}

/** "[logo] •1234" — a card reference with its bank's mark. */
export function CardRef({ bankCode, last4, size = "xs", className }: { bankCode: string | null | undefined; last4: string | null | undefined; size?: BankLogoSize; className?: string }) {
  return (
    <span className={cn("inline-flex min-w-0 items-center gap-1", className)}>
      <BankLogo bankCode={bankCode} size={size} />
      <span className="tabular truncate">{last4 ? `•${last4}` : "—"}</span>
    </span>
  );
}
