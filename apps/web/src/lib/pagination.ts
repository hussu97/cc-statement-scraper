// One pagination standard (CLAUDE.md §4.5): default 100, options 100…2000.
export const PAGE_SIZES = [100, 200, 500, 1000, 2000] as const;
export type PageSize = (typeof PAGE_SIZES)[number];
export const DEFAULT_PAGE_SIZE: PageSize = 100;

export function normalizePageSize(v: unknown): PageSize {
  const n = typeof v === "string" ? Number(v) : v;
  return (PAGE_SIZES as readonly unknown[]).includes(n) ? (n as PageSize) : DEFAULT_PAGE_SIZE;
}

export function normalizePage(v: unknown): number {
  const n = typeof v === "string" ? Number(v) : v;
  return typeof n === "number" && Number.isInteger(n) && n >= 1 ? n : 1;
}

/** Inclusive row range for PostgREST `.range(from, to)`. Pages are 1-based. */
export function pageRange(page: number, size: number): { from: number; to: number } {
  const from = (Math.max(1, page) - 1) * size;
  return { from, to: from + size - 1 };
}

export function pageCount(total: number | null | undefined, size: number): number {
  if (!total || total <= 0) return 1;
  return Math.ceil(total / size);
}
