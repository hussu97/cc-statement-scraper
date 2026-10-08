// Guard (CLAUDE.md §4.2): tokens are the only source of colour. No hex colour
// literals anywhere in src/ — use Tailwind token classes or var(--color-*).
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const SRC = fileURLToPath(new URL("..", import.meta.url));
const ALLOW = [/\.test\.tsx?$/, /\.d\.ts$/];
const HEX = /(?<![&\w])#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})\b/gi;

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : /\.(tsx?|css)$/.test(name) ? [p] : [];
  });
}

export function findHexColors(text: string): string[] {
  // Ignore line comments so prose like "issue #123" in comments can't fail the build.
  const code = text.replace(/^\s*\/\/.*$/gm, "");
  return code.match(HEX) ?? [];
}

describe("no hex colour literals", () => {
  it("detector catches hex and ignores look-alikes", () => {
    expect(findHexColors('color: "#A65A3A"')).toEqual(["#A65A3A"]);
    expect(findHexColors("bg-[#fff]")).toEqual(["#fff"]);
    expect(findHexColors("&#123; #access_token=")).toEqual([]);
  });

  it("src/ contains none outside tests and type declarations", () => {
    const offenders: string[] = [];
    for (const file of walk(SRC)) {
      if (ALLOW.some((re) => re.test(file))) continue;
      const hits = findHexColors(readFileSync(file, "utf8"));
      if (hits.length) offenders.push(`${relative(SRC, file)}: ${hits.join(", ")}`);
    }
    expect(offenders).toEqual([]);
  });
});
