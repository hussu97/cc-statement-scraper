import { readStorage, writeStorage } from "./storage";

export type ThemePref = "system" | "light" | "dark";
const KEY = "ledger.theme";

export function readTheme(): ThemePref {
  const v = readStorage(KEY);
  return v === "light" || v === "dark" ? v : "system";
}

/** Persist and apply: "system" removes data-theme so prefers-color-scheme decides. */
export function applyTheme(pref: ThemePref): void {
  writeStorage(KEY, pref === "system" ? null : pref);
  const el = document.documentElement;
  if (pref === "system") el.removeAttribute("data-theme");
  else el.setAttribute("data-theme", pref);
}
