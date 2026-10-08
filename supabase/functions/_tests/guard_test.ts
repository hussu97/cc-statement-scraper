// Guard (CLAUDE.md §3.1, §6): every function entry point wraps its handler with
// withSentry from _shared/sentry.ts, and every function opts out of gateway JWT
// verification in config.toml because it authenticates callers itself (§3.2).

import { assert } from "jsr:@std/assert@1.0.13";

const functionsDir = new URL("../", import.meta.url);

function functionNames(): string[] {
  const names: string[] = [];
  for (const e of Deno.readDirSync(functionsDir)) {
    if (e.isDirectory && !e.name.startsWith("_") && !e.name.startsWith(".")) names.push(e.name);
  }
  return names.sort();
}

Deno.test("there are function directories to check", () => {
  assert(functionNames().length >= 7, `found only ${functionNames().join(", ")}`);
});

for (const name of functionNames()) {
  Deno.test(`${name}/index.ts uses withSentry`, () => {
    const src = Deno.readTextFileSync(new URL(`${name}/index.ts`, functionsDir));
    assert(
      /import\s*\{[^}]*\bwithSentry\b[^}]*\}\s*from\s*["']\.\.\/_shared\/sentry\.ts["']/.test(src),
      `${name}/index.ts must import withSentry from ../_shared/sentry.ts`,
    );
    assert(
      new RegExp(`Deno\\.serve\\(\\s*withSentry\\(\\s*["']${name}["']`).test(src),
      `${name}/index.ts must call Deno.serve(withSentry("${name}", handler))`,
    );
    const serves = src.match(/Deno\.serve\(/g) ?? [];
    assert(serves.length === 1, `${name}/index.ts must have exactly one Deno.serve`);
  });

  Deno.test(`${name} sets verify_jwt = false in config.toml`, () => {
    const toml = Deno.readTextFileSync(new URL("../config.toml", functionsDir));
    const section = new RegExp(`\\[functions\\.${name.replace(/[-]/g, "\\-")}\\]\\s*\\n\\s*verify_jwt\\s*=\\s*false`);
    assert(section.test(toml), `config.toml needs [functions.${name}] verify_jwt = false`);
  });
}
