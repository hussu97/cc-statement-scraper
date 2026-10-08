import { useMemo } from "react";
import { useInfiniteQuery, type QueryKey } from "@tanstack/react-query";
import { flattenUnique, INFINITE_PAGE_SIZE, latestTotal, nextOffset, type OffsetPage } from "@/lib/infinite";
import type { Page } from "./api";

/**
 * An infinite list over an offset-paged source (`fetch(from, to)` with an
 * exact total). Pages of 100; rows de-duplicated by id across pages. A new
 * `queryKey` (a filter change) starts again from the top.
 */
export function useInfiniteList<T>({
  queryKey,
  fetch,
  idOf,
  enabled = true,
  size = INFINITE_PAGE_SIZE,
}: {
  queryKey: QueryKey;
  fetch: (from: number, to: number) => Promise<Page<T>>;
  idOf: (row: T) => string | null | undefined;
  enabled?: boolean;
  size?: number;
}) {
  const query = useInfiniteQuery({
    queryKey,
    enabled,
    initialPageParam: 0,
    queryFn: ({ pageParam }): Promise<OffsetPage<T>> => fetch(pageParam, pageParam + size - 1),
    getNextPageParam: (_last, all) => nextOffset(all, size),
  });
  const pages = query.data?.pages;
  const items = useMemo(() => flattenUnique(pages ?? [], idOf), [pages, idOf]);
  return { ...query, items, total: latestTotal(pages ?? []) };
}
