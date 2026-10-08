// Contrast guard for the design tokens (WEB-06, WEB-29). Runs with `node --test`
// (part of `pnpm --filter @ledger/tokens check`), so a token edit that drops a
// declared pair below WCAG AA, or makes two category colours look alike, fails CI.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { contrast, deltaE2000 } from "../scripts/color.mjs";

const t = JSON.parse(readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "../tokens.json"), "utf8"));
const THEMES = ["light", "dark"];
const AA_TEXT = 4.5;
const AA_GRAPHICS = 3;

function token(theme, name) {
  const v = name.startsWith("chart.") ? t.chart[theme][name.slice(6)] : t.color[theme][name];
  assert.ok(v, `unknown token ${name} (${theme})`);
  return v;
}

const cats = (theme) => Object.keys(t.chart[theme]).filter((k) => /^cat-\d+$/.test(k));

for (const theme of THEMES) {
  test(`${theme}: every declared text pair meets AA ${AA_TEXT}:1`, () => {
    const fails = t.contrast.text
      .map(([fg, bg]) => [fg, bg, contrast(token(theme, fg), token(theme, bg))])
      .filter(([, , r]) => r < AA_TEXT)
      .map(([fg, bg, r]) => `${fg} on ${bg}: ${r.toFixed(2)}`);
    assert.deepEqual(fails, []);
  });

  test(`${theme}: graphics pairs and every category colour meet ${AA_GRAPHICS}:1 on bg and surface`, () => {
    const pairs = [...t.contrast.graphics, ...cats(theme).flatMap((c) => [[`chart.${c}`, "surface"], [`chart.${c}`, "bg"]])];
    const fails = pairs
      .map(([fg, bg]) => [fg, bg, contrast(token(theme, fg), token(theme, bg))])
      .filter(([, , r]) => r < AA_GRAPHICS)
      .map(([fg, bg, r]) => `${fg} on ${bg}: ${r.toFixed(2)}`);
    assert.deepEqual(fails, []);
  });

  test(`${theme}: category colours are visibly distinct (ΔE2000 ≥ ${t.contrast.categoryMinDeltaE})`, () => {
    const list = cats(theme);
    assert.equal(list.length, 12, "expected cat-1 … cat-12");
    const close = [];
    for (let i = 0; i < list.length; i++)
      for (let j = i + 1; j < list.length; j++) {
        const d = deltaE2000(t.chart[theme][list[i]], t.chart[theme][list[j]]);
        if (d < t.contrast.categoryMinDeltaE) close.push(`${list[i]} / ${list[j]}: ${d.toFixed(1)}`);
      }
    assert.deepEqual(close, []);
  });

  test(`${theme}: "Other" (axis) and Uncategorised are not confused with a category`, () => {
    for (const c of cats(theme)) {
      assert.ok(deltaE2000(t.chart[theme][c], t.chart[theme].uncategorized) >= 10, `${c} vs uncategorized`);
    }
  });
}

test("colour maths matches WCAG reference values", () => {
  assert.equal(contrast("#000000", "#FFFFFF").toFixed(1), "21.0");
  assert.equal(contrast("#777777", "#FFFFFF").toFixed(2), "4.48");
  assert.equal(deltaE2000("#FFFFFF", "#FFFFFF"), 0);
});
