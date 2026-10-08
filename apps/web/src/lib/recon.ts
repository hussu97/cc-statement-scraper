// Turn statement_recon.checks (jsonb) into display rows. Pure; unit-tested.
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

export const RECON_TONE: Record<string, "positive" | "warn" | "danger" | "neutral"> = { ok: "positive", warn: "warn", fail: "danger" };
export const RECON_LABEL: Record<string, string> = { ok: "Reconciled", warn: "Check", fail: "Doesn't add up" };
