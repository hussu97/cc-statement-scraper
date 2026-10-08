import { useEffect, useState } from "react";
import { clampPage, DEFAULT_PAGE_SIZE, type PageSize } from "./pagination";

export function useDebouncedValue<T>(value: T, ms = 350): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

export function useMediaQuery(query: string): boolean {
  const get = () => (typeof window !== "undefined" && window.matchMedia ? window.matchMedia(query).matches : false);
  const [match, setMatch] = useState(get);
  useEffect(() => {
    const mql = window.matchMedia(query);
    const on = () => setMatch(mql.matches);
    on();
    mql.addEventListener("change", on);
    return () => mql.removeEventListener("change", on);
  }, [query]);
  return match;
}

export interface PageState {
  page: number;
  size: PageSize;
  setPage: (p: number) => void;
  setSize: (s: PageSize) => void;
}

/** Local page state for a server-paginated list (standard sizes, default 100). */
export function usePageState(): PageState {
  const [page, setPage] = useState(1);
  const [size, setSizeState] = useState<PageSize>(DEFAULT_PAGE_SIZE);
  return {
    page,
    size,
    setPage,
    setSize: (s: PageSize) => {
      setSizeState(s);
      setPage(1);
    },
  };
}

/**
 * Once a list's total is known, a page past the end (rows removed by an action
 * or a realtime change, or a stale URL) moves to the last page instead of
 * showing an empty or failed list (WEB-01).
 */
export function useClampPage(page: number, size: number, total: number | undefined, go: (page: number) => void): void {
  useEffect(() => {
    if (total === undefined) return;
    const target = clampPage(page, total, size);
    if (target !== null) go(target);
    // `go` is usually an inline closure; the inputs that matter are listed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page, size, total]);
}
