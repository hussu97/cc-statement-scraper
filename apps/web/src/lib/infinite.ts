// Pure helpers for offset-paged infinite lists (phone layouts). Unit-tested.
import { DEFAULT_PAGE_SIZE, normalizePage, normalizePageSize, type PageSize } from "./pagination";

/** Below this width lists scroll forever; at and above it they have numbered pages. */
export const INFINITE_MAX_WIDTH = 767;
export const INFINITE_QUERY = `(max-width: ${INFINITE_MAX_WIDTH}px)`;

/** Every infinite list loads the standard page size (CLAUDE.md §4.5). */
export const INFINITE_PAGE_SIZE: PageSize = DEFAULT_PAGE_SIZE;

export interface OffsetPage<T> {
  rows: T[];
  /** Exact total for the same filters, as of this request. */
  total: number;
}

/**
 * Offset of the next page, or undefined at the end. The offset counts rows
 * as the server returned them (before de-duplication), so it stays aligned
 * with the server's order. A short or empty page also ends the list, so a
 * shrinking result set can never loop.
 */
export function nextOffset<T>(pages: readonly OffsetPage<T>[], size: number): number | undefined {
  if (pages.length === 0) return 0;
  const last = pages[pages.length - 1]!;
  const loaded = pages.reduce((n, p) => n + p.rows.length, 0);
  if (last.rows.length < size || loaded >= last.total) return undefined;
  return loaded;
}

/**
 * All loaded rows in server order, each id once: when rows are inserted while
 * scrolling, the next page repeats a few rows from the previous one, and the
 * first sighting wins.
 */
export function flattenUnique<T>(pages: readonly OffsetPage<T>[], idOf: (row: T) => string | null | undefined): T[] {
  const seen = new Set<string>();
  const out: T[] = [];
  for (const p of pages) {
    for (const r of p.rows) {
      const id = idOf(r);
      if (id == null) {
        out.push(r);
        continue;
      }
      if (seen.has(id)) continue;
      seen.add(id);
      out.push(r);
    }
  }
  return out;
}

/** The newest total the server reported (rows can arrive while scrolling). */
export function latestTotal<T>(pages: readonly OffsetPage<T>[]): number | undefined {
  return pages.length ? pages[pages.length - 1]!.total : undefined;
}

export interface PageSearch {
  page?: number;
  size?: PageSize;
}

/** `?page=&size=` from untrusted search params; defaults are omitted. Pure. */
export function parsePageSearch(raw: Record<string, unknown>): PageSearch {
  const out: PageSearch = {};
  const page = normalizePage(raw.page);
  if (page > 1) out.page = page;
  const size = normalizePageSize(raw.size);
  if (size !== DEFAULT_PAGE_SIZE) out.size = size;
  return out;
}

/** The URL patch for moving to `page` (page 1 drops out of the URL). Pure. */
export function pagePatch(page: number): PageSearch {
  return { page: page > 1 ? page : undefined };
}

/** The URL patch for a new page size: back to page 1, the default size drops out. Pure. */
export function sizePatch(size: PageSize): PageSearch {
  return { page: undefined, size: size === DEFAULT_PAGE_SIZE ? undefined : size };
}
