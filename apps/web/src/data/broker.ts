// broker_portfolio (20261027165732_swissquote_sync.sql): a broker account's synced portfolio,
// broker_position_detail (20261028062806_zerodha_position_detail.sql): one of its positions, and
// broker_accounts_summary (20261027200000_note_verdicts.sql): every synced account in one line.
// Both return jsonb (Json in the generated types); lib/broker.ts and lib/broker-accounts.ts read
// them into their declared shapes.
// Every figure is the server's (CLAUDE.md §2.2).
import { useQuery } from "@tanstack/react-query";
import { supabase, type RpcArgs } from "@/lib/supabase";
import { parseBrokerPortfolio, type BrokerPortfolio } from "@/lib/broker";
import { parseBrokerAccounts, type BrokerAccountSummary } from "@/lib/broker-accounts";
import { parsePositionDetail, type PositionDetail } from "@/lib/broker-detail";
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

/** Every synced broker account (Swissquote) with its totals and the holdings it covers; empty without one. */
export function useBrokerAccounts(profileCode: string) {
  return useQuery({
    queryKey: keys.brokerAccounts(profileCode),
    queryFn: async (): Promise<BrokerAccountSummary[]> => {
      const args: RpcArgs<"broker_accounts_summary"> = { p_profile_code: profileCode };
      return parseBrokerAccounts(must(await supabase.rpc("broker_accounts_summary", args)));
    },
  });
}

/** One position on a broker account by ISIN: as the account shows it, its marks over time and its SIPs; null when never marked. */
export function useBrokerPosition(profileCode: string, accountCode: string, isin: string) {
  return useQuery({
    queryKey: keys.brokerPosition(profileCode, accountCode, isin),
    retry: (n, e) => !isNotFound(e) && n < 2,
    queryFn: async (): Promise<PositionDetail | null> => {
      const args: RpcArgs<"broker_position_detail"> = { p_profile_code: profileCode, p_account_code: accountCode, p_isin: isin };
      return parsePositionDetail(must(await supabase.rpc("broker_position_detail", args)));
    },
  });
}
