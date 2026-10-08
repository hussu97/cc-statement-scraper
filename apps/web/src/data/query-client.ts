import { MutationCache, QueryCache, QueryClient } from "@tanstack/react-query";
import { reportQueryError } from "@/lib/sentry";

export function createQueryClient(): QueryClient {
  return new QueryClient({
    queryCache: new QueryCache({
      onError: (error, query) => reportQueryError(error, `query:${String(query.queryKey[2] ?? query.queryKey[0])}`),
    }),
    mutationCache: new MutationCache({
      onError: (error) => reportQueryError(error, "mutation"),
    }),
    defaultOptions: {
      queries: {
        staleTime: 60_000,
        gcTime: 10 * 60_000,
        refetchOnWindowFocus: false,
        retry: (count, error) => {
          const code = (error as { code?: string }).code ?? "";
          if (/^(42501|P0002|22023|PGRST)/.test(code)) return false;
          return count < 2;
        },
      },
    },
  });
}
