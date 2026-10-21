import { useState } from "react";
import { Coins } from "lucide-react";
import { formLabel, investmentImageUrl } from "@/lib/holdings";
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
