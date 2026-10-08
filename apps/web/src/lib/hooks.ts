import { useCallback, useEffect, useState } from "react";
import { clampPage } from "./pagination";
import { revealScrollLeft, scrollEdges } from "./scroll";

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

/**
 * Callback ref for a horizontal scroller: keeps `data-fade-start` /
 * `data-fade-end` in sync (the `scroll-fade` utility draws the fades) and
 * scrolls the `[data-state=active]` child into view when it changes (WEB-44).
 */
export function useScrollEdges<T extends HTMLElement>(): (el: T | null) => (() => void) | void {
  return useCallback((el: T | null) => {
    if (!el) return;
    const sync = () => {
      const e = scrollEdges(el.scrollLeft, el.scrollWidth, el.clientWidth);
      el.toggleAttribute("data-fade-start", e.start);
      el.toggleAttribute("data-fade-end", e.end);
    };
    const reveal = () => {
      const active = el.querySelector<HTMLElement>('[data-state="active"]');
      if (!active) return;
      // The scroller is `relative`, so offsetLeft is measured in its content box.
      const left = revealScrollLeft(active.offsetLeft, active.offsetLeft + active.offsetWidth, el.scrollLeft, el.clientWidth);
      if (left !== null) el.scrollLeft = left;
      sync();
    };
    reveal();
    el.addEventListener("scroll", sync, { passive: true });
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(sync) : null;
    ro?.observe(el);
    const mo = typeof MutationObserver !== "undefined" ? new MutationObserver(reveal) : null;
    mo?.observe(el, { subtree: true, attributes: true, attributeFilter: ["data-state"] });
    return () => {
      el.removeEventListener("scroll", sync);
      ro?.disconnect();
      mo?.disconnect();
    };
  }, []);
}

/** Callback ref + the element's current content width (ResizeObserver). 0 until measured. */
export function useElementWidth<T extends HTMLElement>(): [(el: T | null) => (() => void) | void, number] {
  const [width, setWidth] = useState(0);
  const ref = useCallback((el: T | null) => {
    if (!el) return;
    setWidth(el.clientWidth);
    if (typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, width];
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
