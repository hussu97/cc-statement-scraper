import { describe, expect, it } from "vitest";
import type { FilterMeta } from "@/data/overview";
import { UNCATEGORIZED_KEY } from "@/lib/trend-filters";
import { cardLabel, trendFilterChips, trendFilterOptions, withoutChip } from "./trend-filter-options";

const CAT_FOOD = `cat_${"f".repeat(26)}`;
const CAT_CAFE = `cat_${"c".repeat(26)}`;
const CRD_MAIN = `crd_${"1".repeat(26)}`;
const CRD_SUPP = `crd_${"2".repeat(26)}`;

const meta: FilterMeta = {
  accounts: [{ account_code: "acc_1", bank_code: "FAB", nickname: null, product_name: null }],
  cards: [
    { card_code: CRD_MAIN, account_code: "acc_1", bank_code: "FAB", last4: "2777", is_supplementary: false },
    { card_code: CRD_SUPP, account_code: "acc_1", bank_code: "FAB", last4: "2132", is_supplementary: true },
  ],
  categories: [
    { category_code: CAT_CAFE, name: "Cafes", kind: "expense", color_token: "cat-2", parent_code: CAT_FOOD, archived: false },
    { category_code: CAT_FOOD, name: "Food", kind: "expense", color_token: "cat-1", parent_code: null, archived: false },
  ],
  banks: [
    { bank_code: "ADCB", name: "ADCB" },
    { bank_code: "FAB", name: "First Abu Dhabi Bank" },
  ],
  date_range: null,
};

describe("trendFilterOptions", () => {
  it("lists Uncategorised first, then categories in tree order", () => {
    const { categories } = trendFilterOptions(meta);
    expect(categories.map((c) => [c.value, c.depth ?? 0])).toEqual([
      [UNCATEGORIZED_KEY, 0],
      [CAT_FOOD, 0],
      [CAT_CAFE, 1],
    ]);
    expect(categories[0]?.label).toBe("Uncategorised");
  });

  it("offers only banks the profile holds an account with", () => {
    expect(trendFilterOptions(meta).banks).toEqual([{ value: "FAB", label: "First Abu Dhabi Bank", bankCode: "FAB" }]);
  });

  it("labels cards as BANK •last4 and hints supplementary ones", () => {
    expect(trendFilterOptions(meta).cards).toEqual([
      { value: CRD_MAIN, label: "FAB •2777", bankCode: "FAB" },
      { value: CRD_SUPP, label: "FAB •2132", bankCode: "FAB", hint: "supp." },
    ]);
    expect(cardLabel({ bank_code: "ADCB", last4: "0001" })).toBe("ADCB •0001");
  });

  it("is empty but safe before filter_meta loads", () => {
    const o = trendFilterOptions(undefined);
    expect(o.banks).toEqual([]);
    expect(o.cards).toEqual([]);
    expect(o.categories.map((c) => c.value)).toEqual([UNCATEGORIZED_KEY]);
  });
});

describe("trend filter chips", () => {
  const options = trendFilterOptions(meta);
  const f = { categories: [CAT_CAFE, UNCATEGORIZED_KEY], banks: ["FAB"], cards: [CRD_SUPP], q: "noon" };

  it("makes one labelled chip per active filter, unknown codes labelled by code", () => {
    expect(trendFilterChips(f, options).map((c) => c.label)).toEqual(["Cafes", "Uncategorised", "First Abu Dhabi Bank", "FAB •2132", "“noon”"]);
    const ghost = `cat_${"9".repeat(26)}`;
    expect(trendFilterChips({ categories: [ghost], banks: [], cards: [] }, options)).toEqual([{ kind: "categories", value: ghost, label: ghost }]);
  });

  it("removes exactly the chip's filter", () => {
    expect(withoutChip(f, { kind: "categories", value: CAT_CAFE })).toEqual({ ...f, categories: [UNCATEGORIZED_KEY] });
    expect(withoutChip(f, { kind: "q", value: "noon" })).toEqual({ categories: f.categories, banks: ["FAB"], cards: [CRD_SUPP] });
  });
});
