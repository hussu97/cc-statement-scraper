/**
 * The product name and the mark's geometry. The geometry mirrors
 * assets/brand/bank-ledger-mark.svg (the one source every icon is rendered
 * from); brand.test.ts fails if they drift.
 */
export const BRAND_NAME = "Bank Ledger";

/** Corner radius of the tile on the mark's 32-unit grid. */
export const MARK_TILE_RX = 8;

export interface MarkRect {
  x: number;
  y: number;
  width: number;
  height: number;
  rx: number;
}

/** An entry, a right-aligned amount, and the double rule under the total. */
export const MARK_GLYPH: readonly MarkRect[] = [
  { x: 8, y: 6, width: 16, height: 4, rx: 2 },
  { x: 14, y: 12, width: 10, height: 4, rx: 2 },
  { x: 8, y: 20, width: 16, height: 2, rx: 1 },
  { x: 8, y: 24, width: 16, height: 2, rx: 1 },
];
