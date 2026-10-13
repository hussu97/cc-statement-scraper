// What a card owes now, as the server computed it (public.v_account_balances via overview).
// Pure display helpers only: the figures are never re-derived here (CLAUDE.md §2.2).
import { formatDate } from "./dates";
import { formatTotal, toAmount, type MoneyInput } from "./money";

export type BalanceAnchor = "statement" | "balance_migration" | "none";

/** "AED 515", a credit balance "AED 12 in credit" (whole units, WEB-34), "—" when unknown; "≈ " when estimated. */
export function formatOutstanding(value: MoneyInput, hasEstimate = false): string {
  const n = toAmount(value);
  if (n === null) return "—";
  const approx = hasEstimate ? "≈ " : "";
  if (n < 0) return `${approx}${formatTotal(-n)} in credit`;
  return `${approx}${formatTotal(n)}`;
}

/** Where the balance comes from, in one short line under it. */
export function balanceAnchorNote(anchor: BalanceAnchor | null | undefined, anchorDate: string | null | undefined): string {
  switch (anchor) {
    case "statement":
      return `Statement of ${formatDate(anchorDate, "short")} + activity since`;
    case "balance_migration":
      return `Card replaced ${formatDate(anchorDate, "short")} + activity since`;
    default:
      return "No balance from the bank yet";
  }
}

/** Why a total may not be the whole story, or null when it is. */
export function outstandingCaveat(complete: boolean, unpricedCount = 0): string | null {
  if (complete) return null;
  if (unpricedCount > 0) return `Excludes ${unpricedCount} ${unpricedCount === 1 ? "charge" : "charges"} without an AED amount`;
  return "Some cards have no balance from the bank yet";
}
