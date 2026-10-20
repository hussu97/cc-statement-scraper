// The app's two modes (Wealth mode, tasks/todo.md §5): Spending (card spend, budgets) and Wealth
// (bank accounts, cash flow, net worth). The mode is the path's: /wealth/* is Wealth, the
// spending screens are Spending, and the shared screens (Review, Rules, Settings) keep the last
// mode. Pure, unit-tested; the shell reads and writes the remembered mode.
import { readStorage, writeStorage } from "./storage";

export const APP_MODES = ["spending", "wealth"] as const;
export type AppMode = (typeof APP_MODES)[number];

export const MODE_INFO: Record<AppMode, { label: string; hint: string; home: "/" | "/wealth" }> = {
  spending: { label: "Spending", hint: "Cards and budgets", home: "/" },
  wealth: { label: "Wealth", hint: "Accounts and net worth", home: "/wealth" },
};

/** Screens that belong to both modes: the sidebar keeps whichever mode you came from. */
export const SHARED_PATHS = ["/review", "/rules", "/settings"] as const;

const under = (path: string, root: string) => path === root || path.startsWith(`${root}/`);

/** The mode a path belongs to, or null for a shared screen. */
export function modeOfPath(path: string): AppMode | null {
  if (under(path, "/wealth") || under(path, "/cash-flow")) return "wealth";
  if (SHARED_PATHS.some((p) => under(path, p))) return null;
  return "spending";
}

/** The mode to show: the path's, else the remembered one, else Spending. */
export function resolveMode(path: string, remembered: string | null | undefined): AppMode {
  return modeOfPath(path) ?? (isAppMode(remembered) ? remembered : "spending");
}

export function isAppMode(v: unknown): v is AppMode {
  return typeof v === "string" && (APP_MODES as readonly string[]).includes(v);
}

const MODE_KEY = "ledger.mode";

/** The last mode shown (localStorage, wrapped: it can be unavailable). */
export function readRememberedMode(): AppMode | null {
  const v = readStorage(MODE_KEY);
  return isAppMode(v) ? v : null;
}

export function rememberMode(mode: AppMode): void {
  writeStorage(MODE_KEY, mode);
}
