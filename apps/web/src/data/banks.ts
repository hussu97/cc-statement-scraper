import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { publicObjectUrl } from "@/lib/public-object";
import { useAuth } from "./auth";
import { keys } from "./keys";
import { mustList } from "./api";

export interface BankRow {
  bank_code: string;
  name: string;
  /** Object name in the public `bank-logos` bucket, e.g. "FAB.png". */
  logo_path: string | null;
}

/** Public Storage bucket holding one PNG per bank (assets/banks, uploaded by scripts/brand/upload-bank-logos.sh). */
export const BANK_LOGO_BUCKET = "bank-logos";

/**
 * Public URL of a bank logo, or null when the bank has none. Object names are
 * `<BANK_CODE>.png`; anything else (a path, a query string) is refused so a
 * row can never point the <img> somewhere unexpected. Pure, unit-tested.
 */
export function bankLogoUrl(logoPath: string | null | undefined, supabaseUrl: string | null | undefined): string | null {
  return publicObjectUrl(BANK_LOGO_BUCKET, logoPath, supabaseUrl, /^[A-Za-z0-9_-]{1,40}\.(png|webp|svg)$/);
}

/** Text shown when there is no logo (or it failed to load): the short code. */
export function bankFallbackText(bankCode: string | null | undefined): string {
  const code = (bankCode ?? "").trim().toUpperCase();
  return code ? code.slice(0, 4) : "?";
}

/** Every bank (reference data, readable by any signed-in user). Cached for the session. */
export function useBanks() {
  const { session } = useAuth();
  return useQuery({
    queryKey: keys.banks,
    enabled: !!session,
    staleTime: 60 * 60_000,
    gcTime: 24 * 60 * 60_000,
    queryFn: async (): Promise<BankRow[]> => mustList(await supabase.from("banks").select("bank_code, name, logo_path").order("bank_code")),
  });
}

/** Name and logo URL for a bank code; the code itself stands in until banks load. */
export function bankInfo(banks: BankRow[] | undefined, bankCode: string | null | undefined, supabaseUrl: string | null | undefined): { name: string; logoUrl: string | null } {
  const row = bankCode ? banks?.find((b) => b.bank_code === bankCode) : undefined;
  return { name: row?.name ?? bankCode ?? "Unknown bank", logoUrl: bankLogoUrl(row?.logo_path, supabaseUrl) };
}
