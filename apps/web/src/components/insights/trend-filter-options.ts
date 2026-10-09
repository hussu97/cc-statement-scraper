// Picker options and chip labels for the Trends filters, from filter_meta. Pure, so it is unit-tested.
import type { FilterMeta } from "@/data/overview";
import { orderCategories } from "@/data/rules";
import { UNCATEGORIZED_KEY, type TrendFilters } from "@/lib/trend-filters";

export type TrendFilterKind = "categories" | "banks" | "cards";

export interface TrendFilterOption {
  value: string;
  label: string;
  /** Bank logo to show beside the label (banks and cards). */
  bankCode?: string;
  /** Category colour token, for a dot. */
  colorToken?: string | null;
  /** Indented under its parent category. */
  depth?: number;
  /** Muted hint after the label ("supp.", "archived"). */
  hint?: string;
}

export type TrendFilterOptions = Record<TrendFilterKind, TrendFilterOption[]>;

/** Card label as on Activity: "FAB •2777". */
export function cardLabel(c: { bank_code: string; last4: string }): string {
  return `${c.bank_code} •${c.last4}`;
}

/**
 * Options for each picker. Categories in tree order with "Uncategorised" first;
 * banks are only those the profile has an account with (filter_meta lists every
 * bank); cards as "BANK •last4", supplementary ones hinted.
 */
export function trendFilterOptions(meta: FilterMeta | undefined): TrendFilterOptions {
  const cats = orderCategories((meta?.categories ?? []).map((c) => ({ ...c, sort_order: 0 })));
  const held = new Set((meta?.accounts ?? []).map((a) => a.bank_code));
  return {
    categories: [
      { value: UNCATEGORIZED_KEY, label: "Uncategorised", colorToken: null },
      ...cats.map((c) => ({
        value: c.category_code,
        label: c.name,
        colorToken: c.color_token,
        depth: c.depth,
        ...(c.archived ? { hint: "archived" } : {}),
      })),
    ],
    banks: (meta?.banks ?? [])
      .filter((b) => held.has(b.bank_code))
      .map((b) => ({ value: b.bank_code, label: b.name || b.bank_code, bankCode: b.bank_code })),
    cards: (meta?.cards ?? []).map((c) => ({
      value: c.card_code,
      label: cardLabel(c),
      bankCode: c.bank_code,
      ...(c.is_supplementary ? { hint: "supp." } : {}),
    })),
  };
}

export interface TrendFilterChip {
  kind: TrendFilterKind | "q";
  value: string;
  label: string;
}

/**
 * One removable chip per active filter, in picker order. A code that is not in
 * filter_meta (a deleted category, meta still loading) still gets a chip so it
 * can be removed; its label is the code until meta knows it.
 */
export function trendFilterChips(f: TrendFilters, options: TrendFilterOptions): TrendFilterChip[] {
  const chips: TrendFilterChip[] = [];
  for (const kind of ["categories", "banks", "cards"] as const) {
    const labelOf = new Map(options[kind].map((o) => [o.value, o.label]));
    for (const value of f[kind]) chips.push({ kind, value, label: labelOf.get(value) ?? value });
  }
  if (f.q) chips.push({ kind: "q", value: f.q, label: `“${f.q}”` });
  return chips;
}

/** Filters with one chip removed. */
export function withoutChip(f: TrendFilters, chip: Pick<TrendFilterChip, "kind" | "value">): TrendFilters {
  if (chip.kind === "q") {
    const { q: _q, ...rest } = f;
    return rest;
  }
  return { ...f, [chip.kind]: f[chip.kind].filter((v) => v !== chip.value) };
}
