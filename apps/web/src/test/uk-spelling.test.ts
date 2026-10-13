// Guard (audit WEB-31): "no category" reads "Uncategorised" everywhere, as the server now says it
// too (pgTAP 46). Identifiers keep their spelling (`UNCATEGORIZED`, `__uncategorized__`,
// `uncategorized_count`): only the capitalised word, which a person reads, is refused.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const SRC = fileURLToPath(new URL("..", import.meta.url));
const US = /\bUncategorized\b/;

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : /\.tsx?$/.test(name) ? [p] : [];
  });
}

describe("UK spelling", () => {
  it("detector catches the word and ignores identifiers", () => {
    expect(US.test('label: "Uncategorized"')).toBe(true);
    expect(US.test("UNCATEGORIZED, __uncategorized__, uncategorized_count, Uncategorised")).toBe(false);
  });

  it('src/ never says "Uncategorized"', () => {
    const offenders = walk(SRC)
      .filter((f) => !f.endsWith("uk-spelling.test.ts") && US.test(readFileSync(f, "utf8")))
      .map((f) => relative(SRC, f));
    expect(offenders).toEqual([]);
  });
});
