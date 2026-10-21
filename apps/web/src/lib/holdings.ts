// Investments (Wealth mode, tasks/todo.md §6): gold and silver holdings. Pure, unit-tested.
// The form's weight is converted to grams as an exact decimal (BigInt, never a float); every
// value, gain and percentage is the server's (holdings_valuation, CLAUDE.md §2.2). Weights and
// purities here are measurements, not money: these helpers only parse and format them.
import { addDays, isISODate, todayDubai, type ISODate } from "./dates";
import { toAmount, type MoneyInput } from "./money";
import { publicObjectUrl } from "./public-object";

// ── exact decimals ─────────────────────────────────────────────────────────

/** A non-negative decimal: value = n / 10^scale. */
interface Dec {
  n: bigint;
  scale: number;
}

/** "1,234.5" → {12345n, 1}. Non-negative plain decimals only; null for anything else. */
export function parseDecimal(raw: string): Dec | null {
  const s = raw.replace(/[,\s]/g, "");
  const m = /^(\d*)(?:\.(\d*))?$/.exec(s);
  if (!m) return null;
  const int = m[1] ?? "";
  const frac = m[2] ?? "";
  if (int === "" && frac === "") return null;
  return { n: BigInt(`${int || "0"}${frac}`), scale: frac.length };
}

/** `d` at `dp` decimal places, rounded half up. */
function roundTo(d: Dec, dp: number): bigint {
  if (d.scale <= dp) return d.n * 10n ** BigInt(dp - d.scale);
  const div = 10n ** BigInt(d.scale - dp);
  const q = d.n / div;
  return (d.n % div) * 2n >= div ? q + 1n : q;
}

/** n / 10^scale as a plain string, trailing zeros trimmed: (116638n, 3) → "116.638", (1000000n, 3) → "1000". */
function formatDecimal(n: bigint, scale: number): string {
  const digits = n.toString().padStart(scale + 1, "0");
  const int = digits.slice(0, digits.length - scale);
  const frac = digits.slice(digits.length - scale).replace(/0+$/, "");
  return frac ? `${int}.${frac}` : int;
}

/** A server decimal string with trailing zeros trimmed ("116.640" → "116.64"); "" when unreadable. */
export function trimDecimal(v: string | null | undefined): string {
  const d = v ? parseDecimal(v) : null;
  return d ? formatDecimal(d.n, d.scale) : "";
}

// ── weight ─────────────────────────────────────────────────────────────────

export const WEIGHT_UNITS = [
  { value: "g", label: "g", grams: "1" },
  { value: "kg", label: "kg", grams: "1000" },
  { value: "tola", label: "tola", grams: "11.6638" },
] as const;
export type WeightUnit = (typeof WEIGHT_UNITS)[number]["value"];

/** holdings.grams is numeric(14,3): at most 11 digits before the point. */
const MAX_GRAMS_INT_DIGITS = 11;

/**
 * A weight in `unit` as grams, an exact decimal string rounded half up to 3 dp ("10" tola →
 * "116.638"). Null when it isn't a number, rounds to 0 g, or is too large to store.
 */
export function toGrams(raw: string, unit: WeightUnit): string | null {
  const d = parseDecimal(raw);
  const f = parseDecimal(WEIGHT_UNITS.find((u) => u.value === unit)?.grams ?? "");
  if (!d || !f) return null;
  const grams = roundTo({ n: d.n * f.n, scale: d.scale + f.scale }, 3);
  if (grams <= 0n || grams >= 10n ** BigInt(MAX_GRAMS_INT_DIGITS + 3)) return null;
  return formatDecimal(grams, 3);
}

/** A holding's weight for display: grams under a kilo ("116.64 g"), kilos from a kilo up ("1 kg", "8.5 kg"). */
export function formatWeight(grams: string | null | undefined): string {
  const d = grams ? parseDecimal(grams) : null;
  if (!d) return "—";
  const kilo = 1000n * 10n ** BigInt(d.scale);
  const [value, unit] = d.n >= kilo ? [formatDecimal(d.n, d.scale + 3), "kg"] : [formatDecimal(d.n, d.scale), "g"];
  return `${groupThousands(value)} ${unit}`;
}

function groupThousands(v: string): string {
  const [int = "", frac] = v.split(".");
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return frac ? `${grouped}.${frac}` : grouped;
}

// ── karat, fineness, purity ────────────────────────────────────────────────

export const METALS = [
  { value: "gold", label: "Gold" },
  { value: "silver", label: "Silver" },
] as const;
export type Metal = (typeof METALS)[number]["value"];

export const KARATS = [24, 22, 21, 18] as const;
export type Karat = (typeof KARATS)[number];

/** 24K fineness in parts per 10,000 (the server's holdings.fineness). 999.9 is the 24K rate itself. */
export const FINENESS = [9999, 9995, 9990, 9950] as const;
export type Fineness = (typeof FINENESS)[number];

export function isKarat(v: unknown): v is Karat {
  return (KARATS as readonly unknown[]).includes(v);
}

export function isFineness(v: unknown): v is Fineness {
  return (FINENESS as readonly unknown[]).includes(v);
}

/** 9999 → "999.9", 9990 → "999", 9950 → "995". */
export function formatFineness(f: number | null | undefined): string {
  return typeof f === "number" && Number.isInteger(f) && f > 0 ? formatDecimal(BigInt(f), 1) : "—";
}

/** A purity fraction from the server ("0.9990") in parts per thousand: "999", "999.9". */
export function formatPurity(p: string | null | undefined): string {
  const d = p ? parseDecimal(p) : null;
  if (!d) return "—";
  return d.scale >= 3 ? formatDecimal(d.n, d.scale - 3) : formatDecimal(d.n * 10n ** BigInt(3 - d.scale), 0);
}

/** Purity typed in parts per thousand ("999", "925", "999.9") as the server's fraction ("0.999"); null when not in (0, 1000]. */
export function purityFraction(raw: string): string | null {
  const d = parseDecimal(raw);
  if (!d) return null;
  const n = roundTo({ n: d.n, scale: d.scale + 3 }, 4); // purity is numeric(5,4)
  if (n <= 0n || n > 10000n) return null;
  return formatDecimal(n, 4);
}

/** "Gold bar · 24K · 999.9", "Gold jewellery · 22K", "Silver coin · 999" ("Gold · 22K" without a form). */
export function holdingKind(h: { metal: string; karat: number | null; fineness: number | null; purity: string | null; form?: string | null }): string {
  const name = formLabel(h.metal, h.form);
  if (h.metal === "silver") return `${name} · ${formatPurity(h.purity)}`;
  const parts = [name, h.karat ? `${h.karat}K` : null, h.karat === 24 && h.fineness ? formatFineness(h.fineness) : null];
  return parts.filter(Boolean).join(" · ");
}

// ── form (bar, coin, jewellery) and its image ──────────────────────────────

export const HOLDING_FORMS = [
  { value: "bar", label: "Bar" },
  { value: "coin", label: "Coin" },
  { value: "jewellery", label: "Jewellery" },
] as const;
export type HoldingShape = (typeof HOLDING_FORMS)[number]["value"];

export function isHoldingShape(v: unknown): v is HoldingShape {
  return HOLDING_FORMS.some((f) => f.value === v);
}

/** The forms a metal comes in: silver is a bar or a coin, never jewellery (the server refuses it). */
export function formOptions(metal: Metal): { value: HoldingShape; label: string }[] {
  return HOLDING_FORMS.filter((f) => metal === "gold" || f.value !== "jewellery");
}

/** save_holding's default form: 24K gold and silver are bars, gold below 24K is jewellery. */
export function defaultForm(metal: Metal, karat: Karat): HoldingShape {
  return metal === "gold" && karat !== 24 ? "jewellery" : "bar";
}

/** "Gold bar", "Silver coin", "Gold jewellery": the image's alt text. */
export function formLabel(metal: string, form: string | null | undefined): string {
  const m = metal === "silver" ? "Silver" : "Gold";
  return isHoldingShape(form) ? `${m} ${form}` : m;
}

/** Public Storage bucket of the holding images (assets/investments, scripts/brand/upload-investment-images.sh). */
export const INVESTMENT_IMAGE_BUCKET = "investment-images";

/** Public URL of a holding's image (holdings_valuation image_path, `<metal>-<form>.jpg`); null for anything else. */
export function investmentImageUrl(imagePath: string | null | undefined, supabaseUrl: string | null | undefined): string | null {
  return publicObjectUrl(INVESTMENT_IMAGE_BUCKET, imagePath, supabaseUrl, /^[a-z]{1,20}-[a-z]{1,20}\.(jpg|png|webp)$/);
}

/**
 * The image of a holding not saved yet (the form's preview). A saved holding uses the server's
 * image_path; this names the same objects so the preview matches what will be saved.
 */
export function draftImagePath(metal: Metal, form: HoldingShape): string {
  return `${metal}-${form}.jpg`;
}

// ── prices ─────────────────────────────────────────────────────────────────

export const QUOTE_LABEL: Record<string, string> = {
  gold_24k: "Gold 24K",
  gold_22k: "Gold 22K",
  gold_21k: "Gold 21K",
  gold_18k: "Gold 18K",
  silver_retail: "Silver",
  gold_spot: "Gold spot",
  silver_spot: "Silver spot",
};

/** The price strip: Dubai retail rates, gold by karat then silver. */
export const PRICE_STRIP = ["gold_24k", "gold_22k", "gold_21k", "gold_18k", "silver_retail"] as const;

/** The price chart's choices (metal_price_series quotes). */
export const PRICE_CHART_QUOTES = [
  { value: "gold_24k", label: "24K gold" },
  { value: "silver_retail", label: "Silver" },
] as const;

export function quoteLabel(quote: string | null | undefined): string {
  return (quote && QUOTE_LABEL[quote]) || "Price";
}

/**
 * A server percentage (already ×100, e.g. "1.25") for display: "+1.25%", "−0.4%", "0%".
 * Null when there is none (no base to compare with).
 */
export function formatPct(pct: MoneyInput, opts: { signed?: boolean } = {}): string | null {
  const n = toAmount(pct);
  if (n === null) return null;
  const body = new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(Math.abs(n));
  const sign = n < 0 ? "−" : opts.signed && n > 0 ? "+" : "";
  return `${sign}${body}%`;
}

/** A gain or change's colour: positive up, danger down, neutral flat or unknown. */
export function signTone(v: MoneyInput): "positive" | "danger" | "neutral" {
  const n = toAmount(v);
  return n === null || n === 0 ? "neutral" : n > 0 ? "positive" : "danger";
}

// ── summary notes ──────────────────────────────────────────────────────────

export interface ValuationCompleteness {
  complete: boolean;
  costs_complete: boolean;
  stale_count: number;
  holdings: readonly { value_aed: string | null; cost_aed: string | null }[];
}

/** Why the totals may not be the whole story, as short phrases (empty when they are). */
export function investmentNotes(v: ValuationCompleteness): string[] {
  const out: string[] = [];
  const unpriced = v.holdings.filter((h) => h.value_aed === null).length;
  if (!v.complete && unpriced > 0) out.push(`${unpriced} ${unpriced === 1 ? "holding has" : "holdings have"} no value yet`);
  // Stale: a metal price over 3 days old, or a plan's, account's or share's value over 45 days old.
  if (v.stale_count > 0) out.push(`${v.stale_count} ${v.stale_count === 1 ? "value is" : "values are"} out of date`);
  return out.map(capitalise);
}

/** The gain's caveat when some holdings have no cost: the gain counts only those with one. */
export function gainNote(v: ValuationCompleteness): string | null {
  if (v.costs_complete) return null;
  const n = v.holdings.filter((h) => h.cost_aed === null).length;
  if (n === 0) return null;
  return `${n} ${n === 1 ? "holding has" : "holdings have"} no cost: the gain counts the rest`;
}

function capitalise(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

// ── chart ──────────────────────────────────────────────────────────────────

/** Days of history on the Investments chart. */
export const INVESTMENT_DAYS = 90;

export function investmentRange(today: ISODate = todayDubai()): { from: ISODate; to: ISODate } {
  return { from: addDays(today, -(INVESTMENT_DAYS - 1)), to: today };
}

export interface HoldingsPoint {
  date: ISODate;
  /** For plotting only (display): null is a gap. */
  value: number | null;
  cost: number | null;
  /** False when some holding had no value that day: the value is part of the total. */
  complete: boolean;
}

export function holdingsPoints(series: readonly { date: string; value_aed: MoneyInput; cost_aed: MoneyInput; complete?: boolean }[]): HoldingsPoint[] {
  return series.map((p) => ({ date: p.date.slice(0, 10), value: toAmount(p.value_aed), cost: toAmount(p.cost_aed), complete: p.complete !== false }));
}

/** The note under the value chart when some day in range counts only part of the holdings; null when every day is whole. */
export function partialDaysNote(points: readonly { complete: boolean }[]): string | null {
  return points.some((p) => !p.complete) ? "Some holdings had no value on some days, so those days show part of the total." : null;
}

export interface PricePoint {
  date: ISODate;
  /** AED per gram, for plotting only. */
  price: number | null;
}

export function pricePoints(series: readonly { date: string; aed_per_gram: MoneyInput }[]): PricePoint[] {
  return series.map((p) => ({ date: p.date.slice(0, 10), price: toAmount(p.aed_per_gram) }));
}

// ── the holding form ───────────────────────────────────────────────────────

export interface HoldingForm {
  name: string;
  metal: Metal;
  weight: string;
  unit: WeightUnit;
  karat: Karat;
  fineness: Fineness;
  /** Parts per thousand, as typed ("999"). */
  purity: string;
  form: HoldingShape;
  /** True once the form was picked (or the holding has one): it then stops following the metal and karat. */
  formChosen: boolean;
  cost: string;
  acquiredOn: string;
  notes: string;
}

/** What save_holding needs: decimal strings, gold's karat and fineness or silver's purity. */
export interface HoldingInput {
  holding_code?: string;
  kind?: "metal";
  name: string;
  metal: Metal;
  grams: string;
  karat?: Karat;
  fineness?: Fineness;
  purity?: string;
  form: HoldingShape;
  cost_aed?: string;
  acquired_on?: ISODate;
  notes?: string;
}

export const EMPTY_HOLDING_FORM: HoldingForm = {
  name: "",
  metal: "gold",
  weight: "",
  unit: "g",
  karat: 24,
  fineness: 9999,
  purity: "999",
  form: "bar",
  formChosen: false,
  cost: "",
  acquiredOn: "",
  notes: "",
};

/** A holding from holdings_valuation as the form's starting point (weight in grams). */
export function holdingToForm(h: {
  name: string;
  metal: string | null;
  grams: string | null;
  karat: number | null;
  fineness: number | null;
  purity: string | null;
  form?: string | null;
  cost_aed: string | null;
  acquired_on: string | null;
  notes: string | null;
}): HoldingForm {
  const metal: Metal = h.metal === "silver" ? "silver" : "gold";
  const karat: Karat = isKarat(h.karat) ? h.karat : 24;
  return {
    name: h.name,
    metal,
    weight: trimDecimal(h.grams),
    unit: "g",
    karat,
    fineness: isFineness(h.fineness) ? h.fineness : 9999,
    purity: h.purity ? formatPurity(h.purity) : "999",
    form: isHoldingShape(h.form) ? h.form : defaultForm(metal, karat),
    formChosen: isHoldingShape(h.form),
    cost: h.cost_aed ?? "",
    acquiredOn: h.acquired_on?.slice(0, 10) ?? "",
    notes: h.notes ?? "",
  };
}

/**
 * The form after a change: until a form is picked it follows the metal and karat (save_holding's
 * default); silver never keeps jewellery.
 */
export function updateHoldingForm(f: HoldingForm, patch: Partial<HoldingForm>): HoldingForm {
  const next = { ...f, ...patch };
  if (patch.form !== undefined) return { ...next, formChosen: true };
  if (!next.formChosen) return { ...next, form: defaultForm(next.metal, next.karat) };
  if (next.metal === "silver" && next.form === "jewellery") return { ...next, form: "bar" };
  return next;
}

/** A cost in AED as typed ("52,000", "AED 1200.5") as a decimal string; null when not a non-negative amount with ≤ 2 decimals. */
export function normalizeCost(raw: string): string | null {
  const s = raw.replace(/,/g, "").replace(/\s/g, "").replace(/^AED/i, "");
  return /^\d{1,12}(\.\d{1,2})?$/.test(s) ? s : null;
}

export const NAME_MAX = 80;
export const NOTES_MAX = 500;

/** Checks the form and builds save_holding's input, or says what to fix. */
export function validateHoldingForm(
  f: HoldingForm,
  today: ISODate = todayDubai(),
): { ok: true; input: HoldingInput } | { ok: false; error: string } {
  const name = f.name.trim();
  if (!name) return { ok: false, error: "Give the holding a name, e.g. Ten tola bar." };
  if (name.length > NAME_MAX) return { ok: false, error: `Keep the name to ${NAME_MAX} characters.` };
  const grams = toGrams(f.weight, f.unit);
  if (grams === null) return { ok: false, error: "Enter the weight as a number above 0, e.g. 10 tola or 116.64 g." };
  if (f.metal === "silver" && f.form === "jewellery") return { ok: false, error: "Silver is recorded as a bar or a coin." };
  const input: HoldingInput = { name, metal: f.metal, grams, form: f.form };
  if (f.metal === "gold") {
    input.karat = f.karat;
    if (f.karat === 24) input.fineness = f.fineness;
  } else {
    const purity = purityFraction(f.purity);
    if (purity === null) return { ok: false, error: "Enter the silver's purity in parts per thousand, e.g. 999 or 925." };
    input.purity = purity;
  }
  if (f.cost.trim()) {
    const cost = normalizeCost(f.cost);
    if (cost === null) return { ok: false, error: "Enter what you paid in AED with at most two decimals, e.g. 52000 or 52,000.50." };
    input.cost_aed = cost;
  }
  if (f.acquiredOn) {
    if (!isISODate(f.acquiredOn)) return { ok: false, error: "Pick the date you bought it, or leave it empty." };
    if (f.acquiredOn > today) return { ok: false, error: "The date bought can't be in the future." };
    input.acquired_on = f.acquiredOn;
  }
  const notes = f.notes.trim();
  if (notes.length > NOTES_MAX) return { ok: false, error: `Keep the notes to ${NOTES_MAX} characters.` };
  if (notes) input.notes = notes;
  return { ok: true, input };
}
