// node --test packages/db-types/scripts/gen-types.test.mjs   (pnpm db:types:test)
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { normalizeTypes, TYPES_FILE } from "./gen-types.mjs";

const committed = readFileSync(TYPES_FILE, "utf8");

const entry = (name, columns, relation, refColumns, comma = ",") =>
  [
    "          {",
    `            foreignKeyName: "${name}"`,
    `            columns: [${columns.map((c) => `"${c}"`).join(", ")}]`,
    "            isOneToOne: false",
    `            referencedRelation: "${relation}"`,
    `            referencedColumns: [${refColumns.map((c) => `"${c}"`).join(", ")}]`,
    `          }${comma}`,
  ].join("\n");

const table = (...entries) =>
  [
    "      v_transactions: {",
    "        Row: {",
    "          bank_code: string | null",
    "        }",
    "        Relationships: [",
    ...entries,
    "        ]",
    "      }",
    "      banks: {",
    "        Relationships: []",
    "      }",
    "",
  ].join("\n");

const BANK = entry("accounts_bank_code_fkey", ["bank_code"], "banks", ["bank_code"]);
const TRANSFER_BANK = entry("accounts_bank_code_fkey", ["transfer_bank_code"], "banks", ["bank_code"]);
const ACCOUNT = entry("transactions_account_fkey", ["profile_code", "account_code"], "accounts", [
  "profile_code",
  "account_code",
]);
const ACCOUNT_VIEW = entry("transactions_account_fkey", ["profile_code", "account_code"], "v_account_balances", [
  "profile_code",
  "account_code",
]);

/** Deterministically permutes every Relationships array (seeded Fisher-Yates). */
function shuffleRelationships(source, seed) {
  let s = seed;
  const rand = () => ((s = (s * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
  return source.replace(/(Relationships: \[\n)([\s\S]*?)(\n\s*\]\n)/g, (_m, open, body, close) => {
    const items = body.split(/(?<=\},)\n/);
    for (let i = items.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [items[i], items[j]] = [items[j], items[i]];
    }
    return open + items.join("\n") + close;
  });
}

test("the two v_transactions bank joins sort the same whichever order the generator emits", () => {
  const sorted = table(BANK, TRANSFER_BANK, ACCOUNT, ACCOUNT_VIEW);
  assert.equal(normalizeTypes(table(TRANSFER_BANK, BANK, ACCOUNT, ACCOUNT_VIEW)), sorted);
  assert.equal(normalizeTypes(table(ACCOUNT_VIEW, ACCOUNT, TRANSFER_BANK, BANK)), sorted);
  assert.equal(normalizeTypes(sorted), sorted);
});

test("ties on the FK name sort by referenced relation before columns (the generator's own order)", () => {
  const toView = entry("x_fkey", ["a"], "v_view", ["a"]);
  const toTable = entry("x_fkey", ["b"], "table", ["b"]);
  assert.equal(normalizeTypes(table(toView, toTable)), table(toTable, toView));
});

test("keeps the generator's separators: a bare last entry stays bare after sorting", () => {
  const bare = table(BANK, entry("accounts_bank_code_fkey", ["transfer_bank_code"], "banks", ["bank_code"], ""));
  const swapped = table(TRANSFER_BANK, entry("accounts_bank_code_fkey", ["bank_code"], "banks", ["bank_code"], ""));
  assert.equal(normalizeTypes(swapped), bare);
});

test("text outside Relationships arrays is untouched", () => {
  const src = "export type Json = string\n  Relationships: []\n  Returns: { a: 1 }[]\n";
  assert.equal(normalizeTypes(src), src);
});

test("the committed database.ts is already normalised", () => {
  assert.equal(normalizeTypes(committed), committed);
});

test("any shuffle of the committed file's Relationships normalises back to it", () => {
  for (const seed of [1, 7, 42, 2026]) {
    const shuffled = shuffleRelationships(committed, seed);
    assert.equal(normalizeTypes(shuffled), committed, `seed ${seed}`);
  }
  // The shuffle really moved entries, so the test is not vacuous.
  assert.notEqual(shuffleRelationships(committed, 42), committed);
});

test("real drift survives normalisation (the check still fails)", () => {
  const renamed = committed.replace('columns: ["transfer_bank_code"]', 'columns: ["transfer_bank"]');
  assert.notEqual(renamed, committed);
  assert.notEqual(normalizeTypes(renamed), committed);

  const dropped = committed.replace(`${TRANSFER_BANK}\n`, "");
  assert.notEqual(dropped, committed);
  assert.notEqual(normalizeTypes(dropped), committed);
});

test("an array in an unexpected shape fails loudly", () => {
  const broken = table(BANK).replace("          {\n            foreignKeyName", "          { foreignKeyName");
  assert.throws(() => normalizeTypes(broken), /expected "\{" in Relationships/);
  const unterminated = "        Relationships: [\n" + BANK;
  assert.throws(() => normalizeTypes(unterminated), /unterminated/);
});
