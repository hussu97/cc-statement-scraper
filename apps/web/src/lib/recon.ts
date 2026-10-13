// Turn statement_recon.checks (jsonb) into display rows. Pure; unit-tested.
// The sums keep two decimals although they are totals (WEB-34): a check that fails by AED 0.40
// must show the 0.40, or the two figures it compares would read the same.
import { formatMoney, formatPercent } from "./money";

export interface ReconCheck {
  key: string;
  label: string;
  ok: boolean | null; // null = informational
  detail?: string;
}

type Checks = Record<string, unknown> | null | undefined;

export function reconChecks(checks: Checks): ReconCheck[] {
  if (!checks || typeof checks !== "object") return [];
  const c = checks as Record<string, unknown>;
  const out: ReconCheck[] = [];
  const bool = (k: string) => (typeof c[k] === "boolean" ? (c[k] as boolean) : null);
  if ("debits_match" in c) out.push({ key: "debits", label: "Debits add up to the statement total", ok: bool("debits_match"), detail: `Lines: ${formatMoney(c.sum_debits as string)}` });
  if ("credits_match" in c) out.push({ key: "credits", label: "Credits add up to the statement total", ok: bool("credits_match"), detail: `Lines: ${formatMoney(c.sum_credits as string)}` });
  if ("balance_equation" in c)
    out.push({
      key: "balance",
      label: "Opening + debits − credits = closing",
      ok: bool("balance_equation"),
      detail: c.expected_closing !== undefined ? `Expected closing ${formatMoney(c.expected_closing as string)}` : undefined,
    });
  if (typeof c.unpriced_lines === "number" && c.unpriced_lines > 0)
    out.push({
      key: "unpriced",
      label: `${c.unpriced_lines} line${c.unpriced_lines === 1 ? "" : "s"} without an AED amount yet, so the totals are approximate`,
      ok: null,
    });
  if (c.no_lines === true)
    out.push({
      key: "no_lines",
      label: typeof c.superseded_lines === "number" && c.superseded_lines > 0 ? "Every line was replaced by a newer parse" : "No lines were read although the statement shows activity",
      ok: false,
    });
  if (c.totals === "not_extracted") out.push({ key: "totals", label: "Statement totals weren't found in the PDF", ok: false });
  if (typeof c.held_lines === "number")
    out.push({ key: "held", label: c.held_lines ? `${c.held_lines} line${c.held_lines === 1 ? "" : "s"} waiting in Review` : "Every line is matched", ok: c.held_lines === 0 });
  if (typeof c.unmatched_sms === "number")
    out.push({
      key: "sms",
      label: c.unmatched_sms ? `${c.unmatched_sms} SMS purchase${c.unmatched_sms === 1 ? "" : "s"} missing from this statement` : "Every SMS purchase in the period is on the statement",
      ok: c.unmatched_sms === 0,
    });
  if (c.sms_coverage !== null && c.sms_coverage !== undefined)
    out.push({ key: "coverage", label: "Purchases also seen by SMS", ok: null, detail: formatPercent(c.sms_coverage as number) });
  if (typeof c.line_count === "number") out.push({ key: "lines", label: "Lines on the statement", ok: null, detail: String(c.line_count) });
  return out;
}

export type ReconTone = "positive" | "warn" | "danger" | "neutral";
/** `n/a`: a history extract has no statement totals, so there is nothing to reconcile (DP-08). Neutral, never an error. */
export const RECON_TONE: Record<string, ReconTone> = { ok: "positive", warn: "warn", fail: "danger", "n/a": "neutral" };
export const RECON_LABEL: Record<string, string> = { ok: "Reconciled", warn: "Check", fail: "Doesn't add up", "n/a": "Nothing to reconcile" };

/** The status chip for a statement_cycles row. Unknown statuses stay neutral. Pure, unit-tested. */
export function reconBadge(status: string | null | undefined): { label: string; tone: ReconTone } {
  if (!status) return { label: "Not checked", tone: "neutral" };
  return { label: RECON_LABEL[status] ?? status, tone: RECON_TONE[status] ?? "neutral" };
}

/** Why a status has no check list, for the expanded row. */
export function reconNote(status: string | null | undefined): string | null {
  if (status === "n/a") return "History exports have no statement totals, so there is nothing to reconcile. Their lines still count in Activity.";
  return null;
}
