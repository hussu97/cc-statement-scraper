// Contrast guard for the design tokens (WEB-06, WEB-29, IOS-19r). Runs with `node --test`
// (part of `pnpm --filter @ledger/tokens check`), so a token edit that drops a
// declared pair below WCAG AA, or makes two category colours look alike, fails CI.
// The web's pairs are contrast.text/graphics; the iPhone app's are contrast.ios.
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
// WEB-17r: 16 hues, so the frequent spending categories each get their own and only rare
// ones share (the seed assignment lives in SQL, private.seed_categories).
const CATEGORY_COUNT = 16;

function token(theme, name) {
  const v = name.startsWith("chart.") ? t.chart[theme][name.slice(6)] : t.color[theme][name];
  assert.ok(v, `unknown token ${name} (${theme})`);
  return v;
}

const cats = (theme) => Object.keys(t.chart[theme]).filter((k) => /^cat-\d+$/.test(k));

const below = (theme, pairs, min) =>
  pairs
    .map(([fg, bg]) => [fg, bg, contrast(token(theme, fg), token(theme, bg))])
    .filter(([, , r]) => r < min)
    .map(([fg, bg, r]) => `${fg} on ${bg}: ${r.toFixed(2)}`);

const PLATFORMS = { web: t.contrast, ios: t.contrast.ios };

test("every platform declares text and graphics pairs", () => {
  for (const [name, p] of Object.entries(PLATFORMS)) {
    assert.ok(p?.text?.length && p?.graphics?.length, `${name} pairs missing`);
  }
});

test("iOS text never uses subtle (glyphs and dividers only)", () => {
  assert.deepEqual(t.contrast.ios.text.filter(([fg]) => fg === "subtle"), []);
});

for (const theme of THEMES) {
  for (const [name, p] of Object.entries(PLATFORMS)) {
    test(`${theme}: every declared ${name} text pair meets AA ${AA_TEXT}:1`, () => {
      assert.deepEqual(below(theme, p.text, AA_TEXT), []);
    });

    test(`${theme}: every declared ${name} graphics pair meets ${AA_GRAPHICS}:1`, () => {
      assert.deepEqual(below(theme, p.graphics, AA_GRAPHICS), []);
    });
  }

  test(`${theme}: every category colour meets ${AA_GRAPHICS}:1 on bg and surface`, () => {
    const pairs = cats(theme).flatMap((c) => [[`chart.${c}`, "surface"], [`chart.${c}`, "bg"]]);
    assert.deepEqual(below(theme, pairs, AA_GRAPHICS), []);
  });

  test(`${theme}: the categorical palette is cat-1 … cat-${CATEGORY_COUNT}`, () => {
    assert.deepEqual(cats(theme), Array.from({ length: CATEGORY_COUNT }, (_, i) => `cat-${i + 1}`));
  });

  test(`${theme}: category colours are visibly distinct (minimum pairwise ΔE2000 ≥ ${t.contrast.categoryMinDeltaE})`, () => {
    const list = cats(theme);
    const close = [];
    let min = Infinity;
    for (let i = 0; i < list.length; i++)
      for (let j = i + 1; j < list.length; j++) {
        const d = deltaE2000(t.chart[theme][list[i]], t.chart[theme][list[j]]);
        min = Math.min(min, d);
        if (d < t.contrast.categoryMinDeltaE) close.push(`${list[i]} / ${list[j]}: ${d.toFixed(1)}`);
      }
    assert.deepEqual(close, []);
    assert.ok(min >= t.contrast.categoryMinDeltaE, `minimum ΔE2000 ${min.toFixed(1)}`);
  });

  test(`${theme}: "Other" (axis) and Uncategorised are not confused with a category`, () => {
    for (const c of cats(theme)) {
      assert.ok(deltaE2000(t.chart[theme][c], t.chart[theme].uncategorized) >= 10, `${c} vs uncategorized`);
      assert.ok(deltaE2000(t.chart[theme][c], t.chart[theme].axis) >= 10, `${c} vs axis (Other)`);
    }
  });
}

test("colour maths matches WCAG reference values", () => {
  assert.equal(contrast("#000000", "#FFFFFF").toFixed(1), "21.0");
  assert.equal(contrast("#777777", "#FFFFFF").toFixed(2), "4.48");
  assert.equal(deltaE2000("#FFFFFF", "#FFFFFF"), 0);
});
