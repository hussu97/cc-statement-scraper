import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import {
  categorizeSchema,
  categorizeUserPrompt,
  countCaptureGroups,
  isTransientLlmError,
  LlmOutputError,
  normalizeAmount,
  normalizeText,
  smsTemplateSchema,
  validateSuggestions,
  validateTemplateProposal,
} from "../_shared/llm.ts";

const M = ["mer_a", "mer_b"];
const C = ["cat_food", "cat_travel"];

Deno.test("validateSuggestions maps refs to codes, drops unknown refs, clamps confidence, one per merchant", () => {
  const out = validateSuggestions(
    {
      suggestions: [
        { merchant: "m1", category: "c1", confidence: 0.7 },
        { merchant: "m1", category: "c2", confidence: 0.9 },
        { merchant: "m2", category: "c1", confidence: 1.7 },
        { merchant: "m3", category: "c1", confidence: 0.9 },
        { merchant: "m2", category: "c9", confidence: 0.9 },
        { merchant: "m2", category: "c1", confidence: "NaN" },
        { merchant: "mer_a", category: "cat_food", confidence: 0.9 },
        "junk",
      ],
    },
    M,
    C,
  );
  assertEquals(out, [
    { merchant_code: "mer_a", category_code: "cat_travel", confidence: 0.9 },
    { merchant_code: "mer_b", category_code: "cat_food", confidence: 1 },
  ]);
  assertThrows(() => validateSuggestions({ nope: [] }, M, C), LlmOutputError);
  assertThrows(() => validateSuggestions("x", M, C), LlmOutputError);
});

Deno.test("categorizeSchema constrains refs with enums; the prompt carries refs, not codes", () => {
  // deno-lint-ignore no-explicit-any
  const s: any = categorizeSchema(2, 3);
  assertEquals(s.properties.suggestions.items.properties.merchant.enum, ["m1", "m2"]);
  assertEquals(s.properties.suggestions.items.properties.category.enum, ["c1", "c2", "c3"]);
  assertEquals(s.properties.suggestions.items.additionalProperties, false);
  const prompt = categorizeUserPrompt(
    [{ category_code: "cat_food", name: "Dining", kind: "spend" }],
    [{ merchant_code: "mer_a", name: "Cafe", examples: ["CAFE 1", "CAFE 2", "CAFE 3", "CAFE 4"] }],
  );
  assertEquals(JSON.parse(prompt), {
    categories: [{ ref: "c1", name: "Dining", kind: "spend" }],
    merchants: [{ ref: "m1", name: "Cafe", examples: ["CAFE 1", "CAFE 2", "CAFE 3"] }],
  });
  assert(!prompt.includes("mer_a") && !prompt.includes("cat_food"));
});

Deno.test("countCaptureGroups ignores non-capturing groups, escapes and classes", () => {
  assertEquals(countCaptureGroups("(a)(?:b)\\(c\\)[(]([0-9]+)"), 2);
  assertEquals(countCaptureGroups("[^)(]+(x)"), 1);
  assertEquals(countCaptureGroups("[]()](y)"), 1);
});

Deno.test("normalizeAmount mirrors private.parse_amount without floats", () => {
  assertEquals(normalizeAmount("1,234.5"), "1234.50");
  assertEquals(normalizeAmount("52.25"), "52.25");
  assertEquals(normalizeAmount("100"), "100.00");
  assertEquals(normalizeAmount("0.005"), "0.01");
  assertEquals(normalizeAmount("19.994"), "19.99");
  assertEquals(normalizeAmount("abc"), null);
  assertEquals(normalizeAmount(null), null);
});

Deno.test("normalizeText mirrors private.normalize_text", () => {
  assertEquals(normalizeText("  Carrefour   City-Centre. "), "CARREFOUR CITY-CENTRE");
  assertEquals(normalizeText(" .. "), null);
});

const BANKS = ["FAB", "ADCB"];
const good = {
  bank_code: "ADCB",
  name: "purchase alert",
  sender_pattern: "^ADCB",
  body_pattern: "(AED|USD) ([0-9,]+(?:\\.[0-9]+)?) .*?card (?:ending )?([0-9]{4}) at (.+?)\\.",
  field_groups: { amount: 2, currency: 1, last4: 3, merchant: 4, date: null, time: null, available: null },
  date_format: null,
  msg_kind: "purchase",
  expect: { amount: "1,052.5", currency: "aed", last4: "x9208", merchant: " Carrefour  city " },
};

Deno.test("validateTemplateProposal normalises a good proposal", () => {
  const t = validateTemplateProposal(good, BANKS);
  assertEquals(t.field_groups, { amount: 2, currency: 1, last4: 3, merchant: 4 });
  assertEquals(t.expect, { amount: "1052.50", currency: "AED", last4: "9208", merchant: "CARREFOUR CITY" });
  assertEquals(t.name, "LLM: purchase alert");
  assertEquals(t.date_format, null);
});

Deno.test("validateTemplateProposal rejects unsafe or inconsistent proposals", () => {
  const bad = (over: Record<string, unknown>) =>
    assertThrows(() => validateTemplateProposal({ ...good, ...over }, BANKS), LlmOutputError);
  bad({ bank_code: "XYZ" });
  bad({ msg_kind: "transfer" });
  bad({ body_pattern: "(?<amount>[0-9]+)" }); // named group
  bad({ body_pattern: "(?=AED)([0-9]+)" }); // lookahead
  bad({ body_pattern: "(a)\\1" }); // backreference
  bad({ body_pattern: "([0-9]+" }); // does not compile
  bad({ field_groups: { amount: 9 } }); // missing capture group
  bad({ field_groups: { amount: 1, currency: 1 } }); // group reused
  bad({ field_groups: { currency: 1 } }); // no amount
  bad({ field_groups: { amount: 2, iban: 1 } }); // unknown field
  bad({ expect: { amount: "lots" } });
  bad({ date_format: "DD/MM/YYYY; drop table" });
});

Deno.test("smsTemplateSchema requires every field (nullable) for structured output", () => {
  // deno-lint-ignore no-explicit-any
  const s: any = smsTemplateSchema(BANKS);
  assertEquals(s.properties.bank_code.enum, BANKS);
  assertEquals(s.properties.field_groups.required.length, 9); // … available, account_ref, counterparty_ref (Phase 2)
  assertEquals(s.properties.msg_kind.enum.includes("account_credit"), true);
  assertEquals(s.additionalProperties, false);
});

Deno.test("isTransientLlmError: output errors are permanent, unknown errors transient", () => {
  assert(!isTransientLlmError(new LlmOutputError("x")));
  assert(isTransientLlmError(new Error("network")));
});
