// Investments beyond metals (tasks/todo.md §7): holding kinds, the plan / broker / share /
// deposit form, values and flows, returns, allocation and saving by holding. Pure, unit-tested.
// Every value, cost, gain, return and share is the server's (holdings_valuation, holding_detail,
// holding_returns, net_worth, cash_flow_savings; CLAUDE.md §2.2): these helpers only parse what
// the user types into decimal strings, group what the server sent, and word it.
import { formatDate, isISODate, todayDubai, type ISODate } from "./dates";
import { formatTotal, toAmount, type MoneyInput } from "./money";
import { formatPct, parseDecimal, trimDecimal } from "./holdings";

// ── kinds ──────────────────────────────────────────────────────────────────

export const HOLDING_KINDS = [
  { value: "metal", label: "Gold or silver", group: "Metals" },
  { value: "plan", label: "Savings plan", group: "Plans" },
  { value: "broker", label: "Broker account", group: "Broker accounts" },
  { value: "security", label: "Shares or fund", group: "Shares & funds" },
  { value: "deposit", label: "Fixed deposit", group: "Deposits" },
  // Added from a term sheet (components/notes), never through the holding form.
  { value: "structured_note", label: "Structured note", group: "Structured notes" },
] as const;
export type HoldingKind = (typeof HOLDING_KINDS)[number]["value"];
export type InvestmentKind = Exclude<HoldingKind, "metal" | "structured_note">;

export function isHoldingKind(v: unknown): v is HoldingKind {
  return HOLDING_KINDS.some((k) => k.value === v);
}

/** A holding's kind; an older server without `kind` only had metals. */
export function kindOf(h: { kind?: string | null }): HoldingKind {
  return isHoldingKind(h.kind) ? h.kind : "metal";
}

export function kindLabel(kind: string | null | undefined): string {
  return HOLDING_KINDS.find((k) => k.value === kind)?.label ?? "Investment";
}

export interface HoldingGroup<T> {
  kind: HoldingKind;
  label: string;
  holdings: T[];
}

/** Holdings in the page's groups (Metals, Plans, Broker accounts, Shares & funds, Deposits), keeping the server's order inside each; empty groups are left out. */
export function groupHoldings<T extends { kind?: string | null }>(holdings: readonly T[]): HoldingGroup<T>[] {
  return HOLDING_KINDS.map((k) => ({ kind: k.value, label: k.group, holdings: holdings.filter((h) => kindOf(h) === k.value) })).filter((g) => g.holdings.length > 0);
}

/** The link picker's order: plans, broker accounts, shares and funds, deposits, then metals; the server's order within each kind. */
export function holdingsForLinking<T extends { kind?: string | null }>(holdings: readonly T[]): T[] {
  const order: HoldingKind[] = ["plan", "broker", "security", "deposit", "metal"];
  return order.flatMap((k) => holdings.filter((h) => kindOf(h) === k));
}

/** A holding's link rule in words: "Links payments named exactly “RI”" / "Links payments containing “RL360”"; null without one. */
export function linkRuleText(pattern: string | null | undefined, exact: boolean | null | undefined): string | null {
  if (!pattern) return null;
  return exact ? `Links payments whose description is exactly “${pattern}”` : `Links payments whose description contains “${pattern}”`;
}

/** What "Update value" records for a kind: a plan's or broker account's value, a share's unit price; metals are priced by the feed and deposits accrue. */
export function valueInput(kind: string | null | undefined): "value" | "unit_price" | null {
  if (kind === "plan" || kind === "broker") return "value";
  if (kind === "security") return "unit_price";
  return null;
}

// ── display ────────────────────────────────────────────────────────────────

/** Units as stored ("20000.000000") for display: "20,000", "12.5". */
export function formatUnits(units: string | null | undefined): string {
  const t = trimDecimal(units);
  if (!t) return "—";
  const [int = "", frac] = t.split(".");
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return frac ? `${grouped}.${frac}` : grouped;
}

/** A rate as stored ("4.250") for display: "4.25%". */
export function formatRate(rate: string | null | undefined): string {
  const t = trimDecimal(rate);
  return t ? `${t}%` : "—";
}

export interface InvestmentFacts {
  kind?: string | null;
  currency?: string | null;
  institution?: string | null;
  units?: string | null;
  symbol?: string | null;
  rate_pct?: string | null;
  maturity_on?: string | null;
}

/** The line under a non-metal holding's name: "RL360 · USD", "DFM · TALABAT · 20,000 units", "Wio · 4.25% · matures 23 Jun 2027". */
export function investmentFacts(h: InvestmentFacts): string {
  const currency = h.currency && h.currency !== "AED" ? h.currency : null;
  const parts: (string | null | undefined)[] = [h.institution?.trim() || kindLabel(h.kind)];
  if (h.kind === "security") parts.push(h.symbol, h.units ? `${formatUnits(h.units)} units` : null, currency);
  else if (h.kind === "deposit") parts.push(h.rate_pct ? formatRate(h.rate_pct) : null, h.maturity_on ? `matures ${formatDate(h.maturity_on.slice(0, 10))}` : null, currency);
  else parts.push(currency);
  return parts.filter(Boolean).join(" · ");
}

/** A value in its own currency ("USD 14,650"); null when unknown. */
export function formatOwnValue(value: MoneyInput, currency: string | null | undefined): string | null {
  return toAmount(value) === null ? null : formatTotal(value, { currency: currency || "AED" });
}

/** A unit price as stored (up to 6 decimals, never rounded away): "AED 1.42", "USD 0.001234". */
export function formatUnitPrice(price: string | null | undefined, currency: string | null | undefined): string {
  const t = trimDecimal(price);
  if (!t) return "—";
  const [int = "", frac = ""] = t.split(".");
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${currency || "AED"} ${grouped}.${frac.padEnd(2, "0")}`;
}

/** The AED line under a foreign-currency value ("≈ AED 53,800"); null for AED holdings or no value. */
export function aedEquivalent(valueAed: MoneyInput, currency: string | null | undefined): string | null {
  if (!currency || currency === "AED" || toAmount(valueAed) === null) return null;
  return `≈ ${formatTotal(valueAed)}`;
}

/** Why a holding has no value yet, by kind. */
export function noValueText(kind: string | null | undefined): string {
  if (kind === "metal") return "No price yet";
  if (kind === "deposit") return "Not started yet";
  return "No value yet";
}

// ── flows and values ───────────────────────────────────────────────────────

export const FLOW_KINDS = [
  { value: "contribution", label: "Money in" },
  { value: "withdrawal", label: "Money out" },
  { value: "income", label: "Income" },
] as const;
export type FlowKind = (typeof FLOW_KINDS)[number]["value"];

export const FLOW_KIND_LABEL: Record<string, string> = { contribution: "Added", withdrawal: "Taken out", income: "Income" };

export const FLOW_SOURCE_LABEL: Record<string, string> = {
  manual: "Entered by you",
  rule: "Linked by the rule",
  link: "Linked by you",
  holding_cost: "Purchase cost",
  import: "Synced from the provider",
};

/** The note beside a stored value: a deposit's comes from its bank's statement, a plan's from the provider sync; null when entered by hand. */
export function valuationSourceLabel(kind: HoldingKind | null, source: string): string | null {
  if (source !== "import") return null;
  return kind === "deposit" ? "From statement" : "Synced";
}

/** How a deposit is valued: from its bank's latest statement when one gave a value, else from its principal. */
export function depositValueNote(h: { rate_pct?: string | null; maturity_on?: string | null }, fromStatement: boolean): string {
  const rate = h.rate_pct ? formatRate(h.rate_pct) : "its rate";
  const maturity = h.maturity_on ? ` on ${formatDate(h.maturity_on.slice(0, 10))}` : "";
  return fromStatement
    ? `From the bank's statements: the latest value, plus simple profit at ${rate} a year since, to maturity${maturity}.`
    : `An estimate: the principal plus simple profit at ${rate} a year, accrued day by day to maturity${maturity}.`;
}

/** A synced plan records a value a day: the value list shows the latest few until asked for all. */
export const VALUE_LIST_LIMIT = 12;

export function visibleValues<T>(values: T[], showAll: boolean): { shown: T[]; hidden: number } {
  const shown = showAll ? values : values.slice(0, VALUE_LIST_LIMIT);
  return { shown, hidden: values.length - shown.length };
}

/** A metal's purchase cost is edited on the holding; every other flow can be removed. */
export function canRemoveFlow(source: string): boolean {
  return source !== "holding_cost";
}

/** "+" for money put into a holding, "−" for money taken out; income paid to you has no sign (display only). */
export function flowSign(kind: string): "+" | "−" | "" {
  return kind === "contribution" ? "+" : kind === "withdrawal" ? "−" : "";
}

// ── typed amounts ──────────────────────────────────────────────────────────

/** A positive decimal as typed ("12,500.5"): ≤ `int` digits before the point and ≤ `dp` after; null otherwise or when 0. */
export function normalizePositive(raw: string, dp: number, int = 12): string | null {
  const s = raw.replace(/[,\s]/g, "").replace(/^[A-Z]{3}/i, "");
  const re = new RegExp(`^\\d{1,${int}}(\\.\\d{1,${dp}})?$`);
  if (!re.test(s)) return null;
  const d = parseDecimal(s);
  return d && d.n > 0n ? s : null;
}

/** A value or price that may be 0 (a plan surrendered to nothing). */
export function normalizeNonNegative(raw: string, dp: number, int = 12): string | null {
  const s = raw.replace(/[,\s]/g, "").replace(/^[A-Z]{3}/i, "");
  return new RegExp(`^\\d{1,${int}}(\\.\\d{1,${dp}})?$`).test(s) ? s : null;
}

/** A profit rate in percent: 0–100 with ≤ 3 decimals (holdings.rate_pct numeric(6,3)). */
export function normalizeRate(raw: string): string | null {
  const s = raw.replace(/[\s%]/g, "");
  if (!/^\d{1,3}(\.\d{1,3})?$/.test(s)) return null;
  const d = parseDecimal(s);
  return d && d.n <= 100n * 10n ** BigInt(d.scale) ? s : null;
}

// ── the investment form (plan, broker, security, deposit) ──────────────────

export const CURRENCIES = ["AED", "USD", "EUR", "GBP", "SAR", "INR"] as const;

export const LINK_MIN = 3;
/** "Match the whole description" allows a 2-character rule (Wio prints RL360 as "RI"). */
export const LINK_MIN_EXACT = 2;
export const LINK_MAX = 60;
export const NAME_MAX = 80;
export const INSTITUTION_MAX = 80;
export const SYMBOL_MAX = 20;
export const NOTES_MAX = 500;
export const FLOW_NOTES_MAX = 200;

export interface InvestmentForm {
  kind: InvestmentKind;
  name: string;
  institution: string;
  currency: string;
  /** Payments whose description contains it (or, with linkExact, equals it) are linked automatically. */
  linkPattern: string;
  /** The whole description must equal the rule, ignoring case. */
  linkExact: boolean;
  units: string;
  symbol: string;
  principal: string;
  rate: string;
  /** Start date: a deposit's start (required), else when the plan or account began (optional). */
  startOn: string;
  maturityOn: string;
  notes: string;
}

export function emptyInvestmentForm(kind: InvestmentKind): InvestmentForm {
  return { kind, name: "", institution: "", currency: kind === "plan" || kind === "broker" ? "USD" : "AED", linkPattern: "", linkExact: false, units: "", symbol: "", principal: "", rate: "", startOn: "", maturityOn: "", notes: "" };
}

/** A holding from holdings_valuation as the form's starting point. */
export function investmentToForm(h: {
  kind?: string | null;
  name: string;
  institution?: string | null;
  currency?: string | null;
  link_pattern?: string | null;
  link_exact?: boolean | null;
  units?: string | null;
  symbol?: string | null;
  principal?: string | null;
  rate_pct?: string | null;
  acquired_on?: string | null;
  maturity_on?: string | null;
  notes?: string | null;
}): InvestmentForm {
  const kind = kindOf(h);
  return {
    kind: kind === "metal" || kind === "structured_note" ? "plan" : kind,
    name: h.name,
    institution: h.institution ?? "",
    currency: h.currency ?? "AED",
    linkPattern: h.link_pattern ?? "",
    linkExact: !!h.link_exact,
    units: trimDecimal(h.units),
    symbol: h.symbol ?? "",
    principal: trimDecimal(h.principal),
    rate: trimDecimal(h.rate_pct),
    startOn: h.acquired_on?.slice(0, 10) ?? "",
    maturityOn: h.maturity_on?.slice(0, 10) ?? "",
    notes: h.notes ?? "",
  };
}

/** What save_holding takes for a plan, broker account, share or deposit (decimal strings). */
export interface InvestmentInput {
  holding_code?: string;
  kind: InvestmentKind;
  name: string;
  currency: string;
  institution?: string;
  link_pattern?: string;
  /** Sent on every save: false (contains) unless the rule must match the whole description. */
  link_exact?: boolean;
  units?: string;
  symbol?: string;
  principal?: string;
  rate_pct?: string;
  acquired_on?: ISODate;
  maturity_on?: ISODate;
  notes?: string;
}

const NAME_EXAMPLE: Record<InvestmentKind, string> = {
  plan: "RL360 plan",
  broker: "IBKR account",
  security: "Talabat shares",
  deposit: "Wio fixed deposit",
};

export function nameExample(kind: InvestmentKind): string {
  return NAME_EXAMPLE[kind];
}

/** Checks the form and builds save_holding's input, or says what to fix. */
export function validateInvestmentForm(f: InvestmentForm, today: ISODate = todayDubai()): { ok: true; input: InvestmentInput } | { ok: false; error: string } {
  const name = f.name.trim();
  if (!name) return { ok: false, error: `Give it a name, e.g. ${nameExample(f.kind)}.` };
  if (name.length > NAME_MAX) return { ok: false, error: `Keep the name to ${NAME_MAX} characters.` };
  const currency = f.currency.trim().toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) return { ok: false, error: "Pick the currency it's held in." };
  const input: InvestmentInput = { kind: f.kind, name, currency };
  const institution = f.institution.trim();
  if (institution.length > INSTITUTION_MAX) return { ok: false, error: `Keep the institution to ${INSTITUTION_MAX} characters.` };
  if (institution) input.institution = institution;

  if (f.kind === "security") {
    const units = normalizePositive(f.units, 6);
    if (units === null) return { ok: false, error: "Enter how many units you hold, e.g. 20000 or 12.5." };
    input.units = units;
    const symbol = f.symbol.trim().toUpperCase();
    if (symbol.length > SYMBOL_MAX) return { ok: false, error: `Keep the symbol to ${SYMBOL_MAX} characters.` };
    if (symbol) input.symbol = symbol;
  }

  if (f.kind === "deposit") {
    const principal = normalizePositive(f.principal, 2);
    if (principal === null) return { ok: false, error: "Enter the amount deposited, with at most two decimals." };
    const rate = normalizeRate(f.rate);
    if (rate === null) return { ok: false, error: "Enter the profit rate a year in percent, e.g. 4.25." };
    if (!isISODate(f.startOn)) return { ok: false, error: "Pick the date the deposit started." };
    if (f.startOn > today) return { ok: false, error: "The start date can't be in the future." };
    if (!isISODate(f.maturityOn) || f.maturityOn <= f.startOn) return { ok: false, error: "Pick a maturity date after the start date." };
    Object.assign(input, { principal, rate_pct: rate, acquired_on: f.startOn, maturity_on: f.maturityOn });
  } else if (f.startOn) {
    if (!isISODate(f.startOn)) return { ok: false, error: "Pick the start date, or leave it empty." };
    if (f.startOn > today) return { ok: false, error: "The start date can't be in the future." };
    input.acquired_on = f.startOn;
  }

  const link = f.linkPattern.trim();
  const min = f.linkExact ? LINK_MIN_EXACT : LINK_MIN;
  if (link && (link.length < min || link.length > LINK_MAX))
    return {
      ok: false,
      error: f.linkExact
        ? `Make the link text ${LINK_MIN_EXACT} to ${LINK_MAX} characters, e.g. RI.`
        : `Make the link text ${LINK_MIN} to ${LINK_MAX} characters, e.g. RL360, or turn on Match the whole description for a 2-character name.`,
    };
  if (link) input.link_pattern = link;
  input.link_exact = !!link && f.linkExact;
  const notes = f.notes.trim();
  if (notes.length > NOTES_MAX) return { ok: false, error: `Keep the notes to ${NOTES_MAX} characters.` };
  if (notes) input.notes = notes;
  return { ok: true, input };
}

// ── Update value and Add flow ──────────────────────────────────────────────

export function validateValueForm(
  kind: string | null | undefined,
  f: { amount: string; asOf: string },
  today: ISODate = todayDubai(),
): { ok: true; input: { value?: string; unit_price?: string; as_of?: ISODate } } | { ok: false; error: string } {
  const what = valueInput(kind);
  if (!what) return { ok: false, error: "This holding is valued automatically." };
  const amount = normalizeNonNegative(f.amount, what === "unit_price" ? 6 : 2);
  if (amount === null)
    return { ok: false, error: what === "unit_price" ? "Enter the price of one unit, e.g. 1.42." : "Enter the value with at most two decimals, e.g. 53800." };
  if (f.asOf && (!isISODate(f.asOf) || f.asOf > today)) return { ok: false, error: "Pick today or an earlier date." };
  const input: { value?: string; unit_price?: string; as_of?: ISODate } = what === "unit_price" ? { unit_price: amount } : { value: amount };
  if (f.asOf && f.asOf !== today) input.as_of = f.asOf;
  return { ok: true, input };
}

export interface FlowFormInput {
  kind: FlowKind;
  flow_date: ISODate;
  amount: string;
  amount_aed?: string;
  notes?: string;
}

export function validateFlowForm(
  currency: string | null | undefined,
  f: { kind: FlowKind; date: string; amount: string; amountAed: string; notes: string },
  today: ISODate = todayDubai(),
): { ok: true; input: FlowFormInput } | { ok: false; error: string } {
  if (!isISODate(f.date) || f.date > today) return { ok: false, error: "Pick the date: today or earlier." };
  const amount = normalizePositive(f.amount, 2);
  if (amount === null) return { ok: false, error: `Enter the amount in ${currency || "AED"}, above 0 with at most two decimals.` };
  const input: FlowFormInput = { kind: f.kind, flow_date: f.date, amount };
  if (currency && currency !== "AED" && f.amountAed.trim()) {
    const aed = normalizePositive(f.amountAed, 2);
    if (aed === null) return { ok: false, error: "Enter the AED amount above 0, or leave it empty to convert it." };
    input.amount_aed = aed;
  }
  const notes = f.notes.trim();
  if (notes.length > FLOW_NOTES_MAX) return { ok: false, error: `Keep the note to ${FLOW_NOTES_MAX} characters.` };
  if (notes) input.notes = notes;
  return { ok: true, input };
}

// ── returns ────────────────────────────────────────────────────────────────

export const RETURN_PERIODS = [
  { value: "all", label: "All time" },
  { value: "ytd", label: "This year" },
  { value: "12m", label: "12 months" },
] as const;
export type ReturnPeriod = (typeof RETURN_PERIODS)[number]["value"];

export interface ReturnFigures {
  start_value_aed: string | null;
  end_value_aed: string | null;
  added_aed: string | null;
  income_aed: string | null;
  growth_aed: string | null;
  simple_pct: string | null;
  annual_pct: string | null;
  complete: boolean;
}

/** "Added AED 12,000 · Grew AED 1,250 (+3.1%) · +6.2% a year", as parts (the server's figures). */
export function returnsParts(r: ReturnFigures): { added: string; grew: string | null; annual: string } {
  const pct = formatPct(r.simple_pct, { signed: true });
  const growth = toAmount(r.growth_aed);
  const grewWord = growth !== null && growth < 0 ? "Lost" : "Grew";
  const grew = growth === null ? null : `${grewWord} ${formatTotal(Math.abs(growth))}${pct ? ` (${pct})` : ""}`;
  const annual = formatPct(r.annual_pct, { signed: true });
  const pending = r.complete ? "Yearly return after 90 days" : "Yearly return not known";
  return { added: `Added ${formatTotal(r.added_aed ?? "0")}`, grew, annual: annual ? `${annual} a year` : pending };
}

type IncompleteCause = "no_value" | "no_money_in" | "no_start";

/**
 * Why a holding is incomplete for a period (holding_returns): no value yet (any period); for all
 * time, no money recorded going in (its value would read as growth); for this year or 12 months,
 * no value at the period's start.
 */
function incompleteCause(h: { end_value_aed?: string | null }, period: ReturnPeriod): IncompleteCause {
  if (h.end_value_aed === null || h.end_value_aed === undefined) return "no_value";
  return period === "all" ? "no_money_in" : "no_start";
}

const CAUSE_NOTE: Record<IncompleteCause, [one: string, many: string]> = {
  no_value: ["has no value yet", "have no value yet"],
  no_money_in: ["has no money recorded going in", "have no money recorded going in"],
  no_start: [
    "has no value at the start of this period (for metals, before price history began)",
    "have no value at the start of this period (for metals, before price history began)",
  ],
};

/** The holdings left out of a period's total, by name and cause. */
export function incompleteNote(holdings: readonly { name: string; complete: boolean; end_value_aed?: string | null }[], period: ReturnPeriod): string | null {
  const out = holdings.filter((h) => !h.complete);
  if (!out.length) return null;
  const parts = (["no_value", "no_money_in", "no_start"] as const).flatMap((cause) => {
    const names = out.filter((h) => incompleteCause(h, period) === cause).map((h) => h.name);
    return names.length ? [`${nameList(names)} ${CAUSE_NOTE[cause][names.length === 1 ? 0 : 1]}`] : [];
  });
  return `${parts.join("; ")}, so ${out.length === 1 ? "it is" : "they are"} left out of the total.`;
}

function nameList(names: string[]): string {
  return names.length <= 3 ? names.join(", ") : `${names.slice(0, 3).join(", ")} and ${names.length - 3} more`;
}

/** Why one holding's return for a period isn't known, in a table cell. */
export function incompleteReason(h: { end_value_aed?: string | null }, period: ReturnPeriod): string {
  return { no_value: "No value yet", no_money_in: "No money recorded going in", no_start: "No value at the start" }[incompleteCause(h, period)];
}

/** The same, as a sentence under one holding's returns. */
export function incompleteDetail(h: { end_value_aed?: string | null }, period: ReturnPeriod): string {
  return {
    no_value: "It has no value yet: record one to see how it has done.",
    no_money_in: "No money is recorded going into it, so its whole value would read as growth. Link the payments that paid into it, or add what you put in.",
    no_start: "No value at the start of this period (for metals, before price history began), so its growth over the period isn't known.",
  }[incompleteCause(h, period)];
}

// ── allocation (net_worth.allocation) ──────────────────────────────────────

export const ALLOCATION_CLASSES: Record<string, { label: string; token: string }> = {
  cash: { label: "Cash", token: "cat-4" },
  gold: { label: "Gold", token: "cat-3" },
  silver: { label: "Silver", token: "cat-9" },
  plan: { label: "Plans", token: "cat-7" },
  broker: { label: "Broker accounts", token: "cat-12" },
  security: { label: "Shares & funds", token: "cat-1" },
  deposit: { label: "Deposits", token: "cat-13" },
  structured_note: { label: "Structured notes", token: "cat-15" },
};

export interface AllocationRow {
  class: string;
  value_aed: string;
  share_pct: string | null;
}

export interface AllocationSlice {
  key: string;
  label: string;
  token: string;
  value: string;
  share: string | null;
  /** The bar segment's width in percent, for drawing only. */
  width: number;
}

/** Assets as slices in the server's order (largest first) and what's owed apart (negative, no share). */
export function allocationSlices(rows: readonly AllocationRow[]): { assets: AllocationSlice[]; owed: string | null } {
  const assets = rows
    .filter((r) => r.class !== "owed")
    .map((r) => {
      const c = ALLOCATION_CLASSES[r.class] ?? { label: r.class, token: "uncategorized" };
      return { key: r.class, label: c.label, token: c.token, value: r.value_aed, share: r.share_pct, width: Math.max(0, toAmount(r.share_pct) ?? 0) };
    });
  const owed = rows.find((r) => r.class === "owed")?.value_aed ?? null;
  return { assets, owed };
}

// ── saving by holding (cash_flow_savings) ──────────────────────────────────

export interface SavingRow {
  month: string;
  holding_code: string | null;
  holding_name: string | null;
  holding_kind: string | null;
  amount_aed: string;
  txn_count: number;
}

export interface SavingLine {
  key: string;
  holdingCode: string | null;
  label: string;
  amount: string;
  count: number;
}

/** One month's saving by holding, in the server's order; "Unassigned" for saving filed by category only. */
export function savingLines(rows: readonly SavingRow[], month: ISODate): SavingLine[] {
  return rows
    .filter((r) => r.month.slice(0, 10) === month)
    .map((r) => ({
      key: r.holding_code ?? "__none",
      holdingCode: r.holding_code,
      label: r.holding_code ? (r.holding_name ?? "Investment") : "Unassigned",
      amount: r.amount_aed,
      count: r.txn_count,
    }));
}
