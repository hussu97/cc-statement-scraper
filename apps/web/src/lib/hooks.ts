import { useEffect, useState } from "react";

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
