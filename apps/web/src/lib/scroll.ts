// Pure helpers for horizontal scrollers (tab strips, wide charts). Unit-tested.

/** Which edges of a horizontal scroller hide content (drives the edge fade, WEB-44). */
export function scrollEdges(scrollLeft: number, scrollWidth: number, clientWidth: number, tolerance = 2): { start: boolean; end: boolean } {
  if (scrollWidth <= clientWidth + tolerance) return { start: false, end: false };
  // RTL scrollers report negative scrollLeft; the magnitude is what matters.
  const left = Math.abs(scrollLeft);
  return { start: left > tolerance, end: left + clientWidth < scrollWidth - tolerance };
}

/**
 * The scrollLeft that brings [itemStart, itemEnd] fully into a view starting
 * at `viewStart` and `viewWidth` wide, with `pad` px to spare, or null when it
 * is already visible. Offsets are relative to the scroller's content box.
 */
export function revealScrollLeft(itemStart: number, itemEnd: number, viewStart: number, viewWidth: number, pad = 24): number | null {
  if (itemStart >= viewStart && itemEnd <= viewStart + viewWidth) return null;
  if (itemStart < viewStart) return Math.max(0, itemStart - pad);
  return Math.max(0, itemEnd - viewWidth + pad);
}
