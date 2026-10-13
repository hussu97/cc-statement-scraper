import { describe, expect, it } from "vitest";
import {
  COLOR_TOKENS,
  cleanConditions,
  countRulesByCategory,
  describeMatch,
  emptyRuleDraft,
  filterMerchants,
  filterRules,
  groupCategories,
  merchantState,
  parseConditions,
  previewArgs,
  ruleErrorMessage,
  ruleTab,
  ruleToDraft,
  slicePage,
  suggestPattern,
  summarizeConditions,
  validateRule,
  type Category,
  type Rule,
} from "./rules";

const cat = (code: string, name: string, extra: Partial<Category> = {}): Category => ({
  archived_at: null,
  category_code: code,
  color_token: "cat-1",
  created_at: "",
  icon: null,
  kind: "spend",
  name,
  parent_code: null,
  profile_code: "prf_x",
  sort_order: 100,
  updated_at: "",
  ...extra,
});

const rule = (extra: Partial<Rule> = {}): Rule => ({
  active: true,
  category_code: "cat_a",
  conditions: {},
  created_at: "",
  match_type: "contains",
  name: null,
  pattern: "COFFEE",
  pattern_upper: "COFFEE",
  priority: 100,
  profile_code: "prf_x",
  rule_code: "rul_1",
  source: "user",
  updated_at: "",
  ...extra,
});

describe("COLOR_TOKENS", () => {
  it("offers the whole categorical palette, cat-1 … cat-16 (WEB-17r)", () => {
    expect(COLOR_TOKENS).toEqual(Array.from({ length: 16 }, (_, i) => `cat-${i + 1}`));
  });
});

describe("ruleTab", () => {
  it("accepts known tabs and falls back to categories", () => {
    expect(ruleTab("merchants")).toBe("merchants");
    expect(ruleTab("nope")).toBe("categories");
    expect(ruleTab(undefined)).toBe("categories");
  });
});

describe("describeMatch", () => {
  it("reads like a sentence", () => {
    expect(describeMatch("contains", " COFFEE ")).toBe("Contains ‘COFFEE’");
    expect(describeMatch("prefix", "UBER")).toBe("Starts with ‘UBER’");
  });
});

describe("conditions", () => {
  it("parses jsonb to strings and keeps unknown keys", () => {
    expect(parseConditions({ amount_min: 50, card_code: "crd_1", junk: { a: 1 } })).toEqual({ amount_min: "50", card_code: "crd_1" });
    expect(parseConditions(null)).toEqual({});
    expect(parseConditions([1])).toEqual({});
  });

  it("summarises conditions in plain words", () => {
    const banks = (c: string) => (c === "FAB" ? "First Abu Dhabi Bank" : c);
    expect(summarizeConditions({ amount_min: "50", amount_max: "200", bank_code: "FAB", direction: "credit" }, banks)).toEqual([
      "AED 50 – 200",
      "First Abu Dhabi Bank",
      "Money in",
    ]);
    expect(summarizeConditions({ amount_max: "10", currency: "usd", kind: "refund" })).toEqual(["Up to AED 10", "In USD", "Refund"]);
    expect(summarizeConditions({ amount_min: "5" })).toEqual(["AED 5 or more"]);
    expect(summarizeConditions({})).toEqual([]);
  });

  it("cleanConditions drops empties and keeps amounts as strings", () => {
    expect(cleanConditions({ amount_min: " 49.99 ", currency: "usd", bank_code: "" })).toEqual({ amount_min: "49.99", currency: "USD" });
  });
});

describe("drafts and preview args", () => {
  it("round-trips a rule into a draft", () => {
    const d = ruleToDraft(rule({ name: "Coffee", conditions: { amount_max: "30" }, source: "seed" }));
    expect(d).toMatchObject({ rule_code: "rul_1", name: "Coffee", conditions: { amount_max: "30" }, source: "seed" });
  });

  it("returns null preview args until the draft is valid", () => {
    expect(previewArgs(emptyRuleDraft())).toBeNull();
    expect(previewArgs(emptyRuleDraft({ pattern: "x", category_code: "cat_a", match_type: "regex" }))).not.toBeNull();
    expect(previewArgs(emptyRuleDraft({ pattern: "   ", category_code: "cat_a", match_type: "regex" }))).toBeNull();
    expect(previewArgs(emptyRuleDraft({ pattern: " tea ", category_code: "cat_a", conditions: { amount_min: "", currency: "eur" } }))).toEqual({
      match_type: "contains",
      pattern: "tea",
      category_code: "cat_a",
      conditions: { currency: "EUR" },
      priority: 100,
    });
    expect(previewArgs({ ...emptyRuleDraft({ pattern: "tea", category_code: "cat_a" }), rule_code: "rul_x" })?.rule_code).toBe("rul_x");
  });

  it("shows the server's 22023 rule problem, not a generic error (WEB-13)", () => {
    const err = (message: string, code?: string) => Object.assign(new Error(message), { code });
    expect(ruleErrorMessage(err("invalid rule: invalid regex: invalid regular expression: quantifier operand invalid", "22023"))).toBe(
      "Invalid regular expression: quantifier operand invalid",
    );
    expect(ruleErrorMessage(err("invalid rule: regex back-references are not allowed", "22023"))).toBe("Regex back-references are not allowed");
    expect(ruleErrorMessage(err("invalid rule: unknown match type x", "22023"))).toBe("Unknown match type x");
    expect(ruleErrorMessage(err("Failed to fetch"))).toBe("Failed to fetch");
    expect(ruleErrorMessage(err("invalid rule: x", "42501"))).toBe("invalid rule: x");
  });

  it("leaves regex syntax to the server's preview (WEB-13r)", () => {
    // Postgres ARE embedded options: JS RegExp throws on these, Postgres accepts them.
    for (const pattern of ["(?b)UBER.*TRIP", "(?i)coffee", "(", "[[:alpha:]]+"]) {
      const d = emptyRuleDraft({ pattern, category_code: "cat_a", match_type: "regex" });
      expect(validateRule(d)).toBeNull();
      expect(previewArgs(d)?.pattern).toBe(pattern);
    }
    expect(validateRule(emptyRuleDraft({ pattern: "  ", category_code: "cat_a", match_type: "regex" }))).toBe("Enter text to match.");
  });

  it("validates amounts as decimal strings", () => {
    expect(validateRule({ ...emptyRuleDraft({ pattern: "a", category_code: "c" }), conditions: { amount_min: "1.234" } })).toMatch(/Amounts/);
  });
});

describe("lists", () => {
  it("filters rules by text and category", () => {
    const list = [rule({ rule_code: "1", pattern: "STARBUCKS" }), rule({ rule_code: "2", pattern: "UBER", name: "rides", category_code: "cat_b" })];
    expect(filterRules(list, { q: "star" }).map((r) => r.rule_code)).toEqual(["1"]);
    expect(filterRules(list, { q: "RIDES" }).map((r) => r.rule_code)).toEqual(["2"]);
    expect(filterRules(list, { categoryCode: "cat_b" }).map((r) => r.rule_code)).toEqual(["2"]);
    expect(filterRules(list, {})).toHaveLength(2);
  });

  it("slices pages", () => {
    const xs = Array.from({ length: 250 }, (_, i) => i);
    expect(slicePage(xs, 1, 100)).toHaveLength(100);
    expect(slicePage(xs, 3, 100)).toEqual(xs.slice(200));
    expect(slicePage(xs, 0, 100)[0]).toBe(0);
  });

  it("counts rules per category", () => {
    const m = countRulesByCategory([{ category_code: "a" }, { category_code: "a" }, { category_code: "b" }]);
    expect(m.get("a")).toBe(2);
    expect(m.get("c")).toBeUndefined();
  });

  it("groups categories into a tree and an archived list", () => {
    const g = groupCategories([
      cat("cat_food", "Food"),
      cat("cat_cafe", "Cafes", { parent_code: "cat_food" }),
      cat("cat_old", "Old", { archived_at: "2026-01-01T00:00:00Z" }),
      cat("cat_child", "Orphan", { parent_code: "cat_old" }),
    ]);
    expect(g.active.map((c) => [c.name, c.depth])).toEqual([
      ["Food", 0],
      ["Cafes", 1],
      ["Orphan", 0],
    ]);
    expect(g.archived.map((c) => c.name)).toEqual(["Old"]);
  });
});

describe("merchants", () => {
  const a = (source: string | null) =>
    source
      ? {
          category_code: "cat_a",
          category_set_hash: null,
          confidence: 0.8,
          created_at: "",
          merchant_code: "mer_1",
          model: null,
          profile_code: "prf_x",
          source,
          updated_at: "",
        }
      : null;

  it("derives how the category is decided", () => {
    expect(merchantState({ assignment: a("manual") })).toBe("manual");
    expect(merchantState({ assignment: a("llm") })).toBe("suggested");
    expect(merchantState({ assignment: null })).toBe("rules");
  });

  it("filters suggestions and by name", () => {
    const rows = [
      { merchant_name: "Starbucks", assignment: a("llm") },
      { merchant_name: "Carrefour", assignment: a("manual") },
      { merchant_name: "Noon", assignment: null },
    ];
    expect(filterMerchants(rows, { suggestionsOnly: true }).map((r) => r.merchant_name)).toEqual(["Starbucks"]);
    expect(filterMerchants(rows, { q: "carr" }).map((r) => r.merchant_name)).toEqual(["Carrefour"]);
  });

  it("suggests a rule pattern from a description", () => {
    expect(suggestPattern("STARBUCKS DUBAI MALL 1234", "Starbucks")).toBe("STARBUCKS");
    expect(suggestPattern("SQ *BLUE BOTTLE  0042 551", "Blue Bottle Coffee")).toBe("SQ *BLUE BOTTLE");
    expect(suggestPattern(null, "Noon")).toBe("NOON");
  });
});
