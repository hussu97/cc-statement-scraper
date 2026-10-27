// broker_portfolio (20261027165732_swissquote_sync.sql): a broker account's synced portfolio. It
// returns jsonb (Json in the generated types); lib/broker.ts reads it into its declared shape.
// Every figure is the server's (CLAUDE.md §2.2).
import { useQuery } from "@tanstack/react-query";
import { supabase, type RpcArgs } from "@/lib/supabase";
import { parseBrokerPortfolio, type BrokerPortfolio } from "@/lib/broker";
import { keys } from "./keys";
import { must } from "./api";
import { isNotFound } from "./wealth";

/** The account's portfolio, or null when it has no broker sync (most accounts). */
export function useBrokerPortfolio(profileCode: string, accountCode: string) {
  return useQuery({
    queryKey: keys.brokerPortfolio(profileCode, accountCode),
    retry: (n, e) => !isNotFound(e) && n < 2,
    queryFn: async (): Promise<BrokerPortfolio | null> => {
      const args: RpcArgs<"broker_portfolio"> = { p_profile_code: profileCode, p_account_code: accountCode };
      return parseBrokerPortfolio(must(await supabase.rpc("broker_portfolio", args)));
    },
  });
}
