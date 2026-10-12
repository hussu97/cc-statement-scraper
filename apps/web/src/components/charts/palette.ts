// Pure colour helpers for charts. Every colour is a token CSS variable.

import { categoryTokens, categoryVar } from "@ledger/tokens/chart";

export { categoryVar };

/** The palette token for the series at `index` when the grouping has no colour of its own (rank order, cycling). */
export function rankToken(index: number): string {
  return categoryTokens[index % categoryTokens.length]!;
}

/**
 * Colour token for a chart series. Category series keep their own
 * `color_token` (so a category looks the same everywhere); other groupings
 * cycle through the categorical palette by rank. "Other" is always neutral.
 */
export function seriesToken(opts: { key: string; colorToken: string | null; index: number; byCategory: boolean }): string | null {
  if (opts.key === "__other") return null;
  if (opts.byCategory) return opts.colorToken;
  return rankToken(opts.index);
}

/** Fill for the folded "Other" series: neutral, and distinct from Uncategorized. */
export const OTHER_FILL = "var(--chart-axis)";

/** CSS fill for a series (null token → the neutral "uncategorized" swatch). */
export function seriesFill(token: string | null, key?: string): string {
  return key === "__other" ? OTHER_FILL : categoryVar(token);
}

/**
 * Heat colour for a level in [0, levels]. Level 0 is the empty cell colour;
 * higher levels mix more accent into the surface.
 */
export function heatFill(level: number, levels = 4): string {
  if (level <= 0) return "var(--color-surface-2)";
  const pct = Math.round((Math.min(level, levels) / levels) * 100);
  return `color-mix(in oklab, var(--color-accent) ${pct}%, var(--color-surface-2))`;
}
