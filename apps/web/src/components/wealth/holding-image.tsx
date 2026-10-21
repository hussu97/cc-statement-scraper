import { useState } from "react";
import { Briefcase, CalendarClock, Coins, PiggyBank, TrendingUp, type LucideIcon } from "lucide-react";
import { formLabel, investmentImageUrl } from "@/lib/holdings";
import { kindLabel, kindOf, type HoldingKind } from "@/lib/investments";
import { cn } from "@/lib/cn";

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string | undefined;

const SIZES = { sm: "size-12 rounded-md", lg: "size-24 rounded-lg" } as const;

/**
 * A holding's photo (public `investment-images` bucket), cropped to a rounded square. The alt
 * text names the metal and form; with no image, or when it fails to load, a neutral placeholder.
 */
export function HoldingImage({ imagePath, metal, form, size = "sm", className }: { imagePath: string | null | undefined; metal: string; form: string | null | undefined; size?: keyof typeof SIZES; className?: string }) {
  const url = investmentImageUrl(imagePath, SUPABASE_URL);
  const [failed, setFailed] = useState<string | null>(null);
  const alt = formLabel(metal, form);
  const show = !!url && failed !== url;
  return (
    <span className={cn("inline-flex shrink-0 items-center justify-center overflow-hidden border border-border bg-surface-2", SIZES[size], className)}>
      {show ? (
        <img src={url} alt={alt} decoding="async" loading="lazy" draggable={false} onError={() => setFailed(url)} className="size-full object-cover" />
      ) : (
        <Coins role="img" aria-label={alt} className={cn("text-subtle", size === "lg" ? "size-8" : "size-5")} />
      )}
    </span>
  );
}

const KIND_ICON: Record<HoldingKind, LucideIcon> = { metal: Coins, plan: PiggyBank, broker: Briefcase, security: TrendingUp, deposit: CalendarClock };

/** A kind's icon, as a plain glyph (group headings, pickers). */
export function KindIcon({ kind, className }: { kind: string | null | undefined; className?: string }) {
  const Icon = KIND_ICON[kindOf({ kind })];
  return <Icon aria-hidden className={className} />;
}

/** A holding's picture: a metal's photo, else its kind's icon in the same rounded square. */
export function HoldingAvatar({
  h,
  size = "sm",
  className,
}: {
  h: { kind?: string | null; image_path?: string | null; metal?: string | null; form?: string | null };
  size?: keyof typeof SIZES;
  className?: string;
}) {
  const kind = kindOf(h);
  if (kind === "metal") return <HoldingImage imagePath={h.image_path} metal={h.metal ?? "gold"} form={h.form} size={size} className={className} />;
  const Icon = KIND_ICON[kind];
  return (
    <span className={cn("inline-flex shrink-0 items-center justify-center border border-border bg-surface-2 text-ink-2", SIZES[size], className)}>
      <Icon role="img" aria-label={kindLabel(kind)} className={size === "lg" ? "size-8" : "size-5"} />
    </span>
  );
}
