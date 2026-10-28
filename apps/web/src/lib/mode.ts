// The app's modes (Wealth mode, tasks/todo.md §5; India, §12): Spending (card spend, budgets), Wealth
// (bank accounts, investments, cash flow, net worth) and India (Zerodha Kite and Coin, apart from
// Wealth; only on a ledger that has them). The mode is the path's: /wealth/* is Wealth, /india/* is
// India, the spending screens are Spending, and the shared screens (Review, Rules, Settings) keep
// the last mode. Pure, unit-tested; the shell reads and writes the remembered mode.
import { readStorage, writeStorage } from "./storage";

export const APP_MODES = ["spending", "wealth", "india"] as const;
export type AppMode = (typeof APP_MODES)[number];

export const MODE_INFO: Record<AppMode, { label: string; hint: string; home: "/" | "/wealth" | "/india" }> = {
  spending: { label: "Spending", hint: "Cards and budgets", home: "/" },
  wealth: { label: "Wealth", hint: "Accounts, investments, net worth", home: "/wealth" },
  india: { label: "India", hint: "Zerodha Kite and Coin", home: "/india" },
};

/** Screens that belong to both modes: the sidebar keeps whichever mode you came from. */
export const SHARED_PATHS = ["/review", "/rules", "/settings"] as const;

const under = (path: string, root: string) => path === root || path.startsWith(`${root}/`);

/** The mode a path belongs to, or null for a shared screen. */
export function modeOfPath(path: string): AppMode | null {
  if (under(path, "/wealth") || under(path, "/cash-flow")) return "wealth";
  if (under(path, "/india")) return "india";
  if (SHARED_PATHS.some((p) => under(path, p))) return null;
  return "spending";
}

/**
 * The mode to show: the path's, else the remembered one, else Spending. A remembered India falls
 * back to Spending once the ledger is known not to have it (`indiaAvailable` false; undefined while
 * that is still loading).
 */
export function resolveMode(path: string, remembered: string | null | undefined, indiaAvailable?: boolean): AppMode {
  const fromPath = modeOfPath(path);
  if (fromPath) return fromPath;
  if (!isAppMode(remembered)) return "spending";
  return remembered === "india" && indiaAvailable === false ? "spending" : remembered;
}

/**
 * The modes the switcher offers: India only when the ledger has a Kite or Coin account
 * (india_overview.available), or when it is the mode on screen (a direct visit to /india).
 */
export function visibleModes(indiaAvailable: boolean | undefined, current: AppMode): AppMode[] {
  return APP_MODES.filter((m) => m !== "india" || indiaAvailable === true || current === "india");
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
