import { describe, expect, it } from "vitest";
import {
  EMPTY_HOLDING_FORM,
  defaultForm,
  draftImagePath,
  formLabel,
  formOptions,
  investmentImageUrl,
  updateHoldingForm,
  formatFineness,
  formatPct,
  formatPurity,
  formatWeight,
  gainNote,
  holdingKind,
  holdingToForm,
  holdingsPoints,
  investmentNotes,
  investmentRange,
  normalizeCost,
  parseDecimal,
  pricePoints,
  purityFraction,
  quoteLabel,
  signTone,
  toGrams,
  trimDecimal,
  validateHoldingForm,
  type HoldingForm,
} from "./holdings";

const TODAY = "2026-10-21";

describe("toGrams (exact decimal, 3 dp)", () => {
  it("converts tola at 11.6638 g with no float error", () => {
    expect(toGrams("10", "tola")).toBe("116.638");
    expect(toGrams("1", "tola")).toBe("11.664"); // 11.6638 rounds half up to 3 dp
    expect(toGrams("0.5", "tola")).toBe("5.832"); // 5.8319
    expect(toGrams("3", "tola")).toBe("34.991"); // 34.9914
    expect(toGrams("100", "tola")).toBe("1166.38");
  });

  it("converts kilos and keeps grams as typed", () => {
    expect(toGrams("1", "kg")).toBe("1000");
    expect(toGrams("1.2345", "kg")).toBe("1234.5");
    expect(toGrams("0.0001", "kg")).toBe("0.1");
    expect(toGrams("116.64", "g")).toBe("116.64");
    expect(toGrams("0.1", "g")).toBe("0.1");
    expect(toGrams("1,000.5", "g")).toBe("1000.5");
    expect(toGrams(" 12 ", "g")).toBe("12");
    expect(toGrams("5.", "g")).toBe("5");
    expect(toGrams(".5", "g")).toBe("0.5");
  });

  it("rounds half up at the third decimal", () => {
    expect(toGrams("1.0005", "g")).toBe("1.001");
    expect(toGrams("1.0004", "g")).toBe("1");
    expect(toGrams("0.30000000000000004", "g")).toBe("0.3");
  });

  it("refuses what isn't a weight above 0 or doesn't fit numeric(14,3)", () => {
    for (const bad of ["", " ", ".", "abc", "-1", "1e3", "1.2.3", "0", "0.0004"]) expect(toGrams(bad, "g")).toBeNull();
    expect(toGrams("99999999999.999", "g")).toBe("99999999999.999");
    expect(toGrams("100000000000", "g")).toBeNull();
    expect(toGrams("100000000", "kg")).toBeNull();
  });
});

describe("decimals", () => {
  it("parses non-negative plain decimals only", () => {
    expect(parseDecimal("1,234.50")).toEqual({ n: 123450n, scale: 2 });
    expect(parseDecimal("-1")).toBeNull();
    expect(trimDecimal("116.640")).toBe("116.64");
    expect(trimDecimal("1000.000")).toBe("1000");
    expect(trimDecimal(null)).toBe("");
  });
});

describe("display", () => {
  it("shows grams under a kilo and kilos from a kilo up", () => {
    expect(formatWeight("116.640")).toBe("116.64 g");
    expect(formatWeight("999.999")).toBe("999.999 g");
    expect(formatWeight("1000.000")).toBe("1 kg");
    expect(formatWeight("8000.000")).toBe("8 kg");
    expect(formatWeight("1500.5")).toBe("1.5005 kg");
    expect(formatWeight("1234567")).toBe("1,234.567 kg");
    expect(formatWeight(null)).toBe("—");
  });

  it("names karat, fineness and purity", () => {
    expect(formatFineness(9999)).toBe("999.9");
    expect(formatFineness(9995)).toBe("999.5");
    expect(formatFineness(9990)).toBe("999");
    expect(formatFineness(9950)).toBe("995");
    expect(formatFineness(null)).toBe("—");
    expect(formatPurity("0.9990")).toBe("999");
    expect(formatPurity("0.9999")).toBe("999.9");
    expect(formatPurity("0.925")).toBe("925");
    expect(formatPurity("1")).toBe("1000");
    expect(holdingKind({ metal: "gold", karat: 24, fineness: 9950, purity: null })).toBe("Gold · 24K · 995");
    expect(holdingKind({ metal: "gold", karat: 22, fineness: null, purity: null })).toBe("Gold · 22K");
    expect(holdingKind({ metal: "silver", karat: null, fineness: null, purity: "0.9990" })).toBe("Silver · 999");
    expect(holdingKind({ metal: "gold", karat: 24, fineness: 9999, purity: null, form: "bar" })).toBe("Gold bar · 24K · 999.9");
    expect(holdingKind({ metal: "silver", karat: null, fineness: null, purity: "0.925", form: "coin" })).toBe("Silver coin · 925");
  });

  it("formats the server's percentages and signs", () => {
    expect(formatPct("1.25", { signed: true })).toBe("+1.25%");
    expect(formatPct("-0.40", { signed: true })).toBe("−0.4%");
    expect(formatPct("0.00", { signed: true })).toBe("0%");
    expect(formatPct("12.5")).toBe("12.5%");
    expect(formatPct(null)).toBeNull();
    expect(signTone("10.00")).toBe("positive");
    expect(signTone("-0.01")).toBe("danger");
    expect(signTone("0")).toBe("neutral");
    expect(signTone(null)).toBe("neutral");
    expect(quoteLabel("gold_24k")).toBe("Gold 24K");
    expect(quoteLabel("silver_retail")).toBe("Silver");
    expect(quoteLabel("junk")).toBe("Price");
  });
});

describe("summary notes", () => {
  const h = (value_aed: string | null, cost_aed: string | null) => ({ value_aed, cost_aed });

  it("says nothing when everything is priced, fresh and costed", () => {
    const v = { complete: true, costs_complete: true, stale_count: 0, holdings: [h("10", "5")] };
    expect(investmentNotes(v)).toEqual([]);
    expect(gainNote(v)).toBeNull();
  });

  it("names missing and stale prices, and holdings with no cost", () => {
    const v = { complete: false, costs_complete: false, stale_count: 2, holdings: [h(null, null), h("10", null), h("10", "5")] };
    expect(investmentNotes(v)).toEqual(["1 holding has no price yet", "2 prices are over 3 days old"]);
    expect(gainNote(v)).toBe("2 holdings have no cost: the gain counts the rest");
  });
});

describe("chart", () => {
  it("spans 90 days, today included", () => {
    expect(investmentRange(TODAY)).toEqual({ from: "2026-07-24", to: TODAY });
  });

  it("keeps a null day a gap, never a zero", () => {
    expect(holdingsPoints([{ date: "2026-10-01", value_aed: null, cost_aed: "100.00" }, { date: "2026-10-02", value_aed: "120.50", cost_aed: "100.00" }])).toEqual([
      { date: "2026-10-01", value: null, cost: 100 },
      { date: "2026-10-02", value: 120.5, cost: 100 },
    ]);
    expect(pricePoints([{ date: "2026-10-01", aed_per_gram: null }, { date: "2026-10-02", aed_per_gram: "489.500000" }])).toEqual([
      { date: "2026-10-01", price: null },
      { date: "2026-10-02", price: 489.5 },
    ]);
  });
});

describe("the holding form", () => {
  const form = (patch: Partial<HoldingForm>): HoldingForm => ({ ...EMPTY_HOLDING_FORM, name: "Ten tola bar", weight: "10", unit: "tola", ...patch });

  it("builds a 24K bar with its fineness, in grams", () => {
    expect(validateHoldingForm(form({ fineness: 9950, cost: "52,000", acquiredOn: "2026-10-01", notes: "  safe box " }), TODAY)).toEqual({
      ok: true,
      input: { name: "Ten tola bar", metal: "gold", grams: "116.638", form: "bar", karat: 24, fineness: 9950, cost_aed: "52000", acquired_on: "2026-10-01", notes: "safe box" },
    });
  });

  it("sends no fineness below 24K and no gold fields for silver", () => {
    const g = validateHoldingForm(form({ karat: 22, fineness: 9950, form: "jewellery" }), TODAY);
    expect(g).toEqual({ ok: true, input: { name: "Ten tola bar", metal: "gold", grams: "116.638", form: "jewellery", karat: 22 } });
    const s = validateHoldingForm(form({ metal: "silver", weight: "1", unit: "kg", purity: "925", form: "coin" }), TODAY);
    expect(s).toEqual({ ok: true, input: { name: "Ten tola bar", metal: "silver", grams: "1000", form: "coin", purity: "0.925" } });
  });

  it("says what to fix", () => {
    const err = (f: HoldingForm) => {
      const v = validateHoldingForm(f, TODAY);
      return v.ok ? null : v.error;
    };
    expect(err(form({ name: "  " }))).toMatch(/name/);
    expect(err(form({ name: "x".repeat(81) }))).toMatch(/80 characters/);
    expect(err(form({ weight: "0" }))).toMatch(/weight/);
    expect(err(form({ weight: "ten" }))).toMatch(/weight/);
    expect(err(form({ metal: "silver", purity: "1001" }))).toMatch(/purity/);
    expect(err(form({ metal: "silver", purity: "" }))).toMatch(/purity/);
    expect(err(form({ cost: "-5" }))).toMatch(/paid/);
    expect(err(form({ cost: "12.345" }))).toMatch(/paid/);
    expect(err(form({ acquiredOn: "2026-10-22" }))).toMatch(/future/);
    expect(err(form({ notes: "x".repeat(501) }))).toMatch(/500/);
    expect(err(form({ metal: "silver", form: "jewellery" }))).toMatch(/bar or a coin/);
  });

  it("parses purity in parts per thousand and costs in AED", () => {
    expect(purityFraction("999")).toBe("0.999");
    expect(purityFraction("999.9")).toBe("0.9999");
    expect(purityFraction("1000")).toBe("1");
    expect(purityFraction("0")).toBeNull();
    expect(normalizeCost("AED 1,200.5")).toBe("1200.5");
    expect(normalizeCost("0")).toBe("0");
    expect(normalizeCost("1.234")).toBeNull();
  });

  it("starts an edit from the holding, in grams", () => {
    const f = holdingToForm({
      name: "Silver bars",
      metal: "silver",
      grams: "8000.000",
      karat: null,
      fineness: null,
      purity: "0.9990",
      cost_aed: "52000.00",
      acquired_on: "2026-08-01",
      notes: null,
    });
    expect(f).toEqual({ ...EMPTY_HOLDING_FORM, name: "Silver bars", metal: "silver", weight: "8000", unit: "g", purity: "999", cost: "52000.00", acquiredOn: "2026-08-01" });
    expect(holdingToForm({ name: "Coin", metal: "gold", grams: "8", karat: 22, fineness: null, purity: null, form: "coin", cost_aed: null, acquired_on: null, notes: null })).toMatchObject({
      karat: 22,
      form: "coin",
      formChosen: true,
    });
    // A round trip saves the same grams and purity.
    expect(validateHoldingForm(f, TODAY)).toMatchObject({ ok: true, input: { grams: "8000", purity: "0.999", cost_aed: "52000.00" } });
  });
});

describe("form and image", () => {
  it("offers jewellery for gold only, and defaults as save_holding does", () => {
    expect(formOptions("gold").map((o) => o.value)).toEqual(["bar", "coin", "jewellery"]);
    expect(formOptions("silver").map((o) => o.value)).toEqual(["bar", "coin"]);
    expect(defaultForm("gold", 24)).toBe("bar");
    expect(defaultForm("gold", 22)).toBe("jewellery");
    expect(defaultForm("gold", 18)).toBe("jewellery");
    expect(defaultForm("silver", 24)).toBe("bar");
  });

  it("follows the metal and karat until a form is picked; silver drops jewellery", () => {
    let f = updateHoldingForm(EMPTY_HOLDING_FORM, { karat: 22 });
    expect(f.form).toBe("jewellery");
    f = updateHoldingForm(f, { karat: 24 });
    expect(f.form).toBe("bar");
    f = updateHoldingForm(f, { form: "coin" });
    expect(f).toMatchObject({ form: "coin", formChosen: true });
    f = updateHoldingForm(f, { karat: 21 });
    expect(f.form).toBe("coin");
    f = updateHoldingForm(updateHoldingForm(f, { form: "jewellery" }), { metal: "silver" });
    expect(f.form).toBe("bar");
  });

  it("builds the public investment-images URL and refuses anything but a bare name", () => {
    const base = "http://127.0.0.1:54321";
    expect(investmentImageUrl("gold-bar.jpg", base)).toBe("http://127.0.0.1:54321/storage/v1/object/public/investment-images/gold-bar.jpg");
    expect(investmentImageUrl("silver-coin.jpg", "https://x.supabase.co/")).toBe("https://x.supabase.co/storage/v1/object/public/investment-images/silver-coin.jpg");
    for (const bad of ["../gold-bar.jpg", "gold-bar.jpg?x=1", "https://evil/x.jpg", "gold bar.jpg", "", null]) expect(investmentImageUrl(bad, base)).toBeNull();
    expect(investmentImageUrl("gold-bar.jpg", undefined)).toBeNull();
    expect(draftImagePath("gold", "jewellery")).toBe("gold-jewellery.jpg");
    expect(formLabel("silver", "coin")).toBe("Silver coin");
    expect(formLabel("gold", null)).toBe("Gold");
  });
});
