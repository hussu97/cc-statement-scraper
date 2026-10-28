// india_overview (India mode, tasks/todo.md §12): Zerodha Kite and Coin together, in INR with AED
// beside it. It returns jsonb; lib/india.ts reads it into its declared shape. Every figure is the
// server's (CLAUDE.md §2.2).
import { useQuery } from "@tanstack/react-query";
import type { PostgrestError } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { parseIndiaOverview, type IndiaOverview } from "@/lib/india";
import type { InvestmentPeriod } from "@/lib/investments";
import { keys } from "./keys";
import { must } from "./api";

interface IndiaOverviewArgs {
  p_profile_code: string;
  p_period: InvestmentPeriod;
}

/**
 * The call, typed here until `pnpm db:types` carries india_overview (the function is newer than
 * the generated types): its arguments are checked against IndiaOverviewArgs and its jsonb result is
 * read by parseIndiaOverview, exactly as a generated `Json` return would be.
 */
type IndiaRpc = (fn: "india_overview", args: IndiaOverviewArgs) => PromiseLike<{ data: unknown; error: PostgrestError | null; status: number }>;
const indiaRpc = supabase.rpc.bind(supabase) as unknown as IndiaRpc;

/** The ledger's India accounts and their totals for a period (90 days by default). */
export function useIndiaOverview(profileCode: string | null, period: InvestmentPeriod = "90d") {
  return useQuery({
    queryKey: keys.india(profileCode ?? "", period),
    enabled: !!profileCode,
    // A period switch keeps the last figures on screen; another ledger's never stand in.
    placeholderData: (prev, prevQuery) => (prev && prevQuery?.queryKey[1] === profileCode ? prev : undefined),
    queryFn: async (): Promise<IndiaOverview> => {
      const args: IndiaOverviewArgs = { p_profile_code: profileCode!, p_period: period };
      return parseIndiaOverview(must(await indiaRpc("india_overview", args)));
    },
  });
}

/**
 * Whether the ledger has India (a Kite or Coin account): true or false once known, undefined while
 * loading or when the call fails, so the switcher never offers India on a guess. Shares the
 * Overview's default-period query.
 */
export function useIndiaAvailable(profileCode: string | null): boolean | undefined {
  const q = useIndiaOverview(profileCode);
  return q.isSuccess && !q.isPlaceholderData ? q.data.available : undefined;
}
