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

// X-16: .env.example lists every key the code reads (names only, never values).
Deno.test(".env.example covers every env key the functions read, with no values", () => {
  const injected = new Set(["SUPABASE_URL", "SB_REGION", "SB_EXECUTION_ID"]);
  const read = new Set<string>();
  const walk = (dir: URL) => {
    for (const e of Deno.readDirSync(dir)) {
      if (e.isDirectory && e.name !== "_tests") walk(new URL(`${e.name}/`, dir));
      else if (e.isFile && e.name.endsWith(".ts")) {
        const src = Deno.readTextFileSync(new URL(e.name, dir));
        for (const m of src.matchAll(/(?:env\.get|envNumber)\("([A-Z0-9_]+)"/g)) read.add(m[1]);
      }
    }
  };
  walk(functionsDir);
  // oauth.ts builds these names from the provider prefix.
  for (const p of ["GMAIL", "MS"]) for (const k of ["ID", "SECRET"]) read.add(`${p}_OAUTH_CLIENT_${k}`);
  const example = Deno.readTextFileSync(new URL(".env.example", functionsDir));
  const lines = example.split("\n").filter((l) => /^[A-Z0-9_]+=/.test(l));
  for (const l of lines) assert(/^[A-Z0-9_]+=$/.test(l), `.env.example must not hold a value: ${l.split("=")[0]}`);
  const listed = new Set(lines.map((l) => l.split("=")[0]));
  const missing = [...read].filter((k) => !injected.has(k) && !listed.has(k)).sort();
  assert(missing.length === 0, `.env.example is missing: ${missing.join(", ")}`);
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

// 28 Oct 2026: Supabase's bundler timed out fetching jsr:@std/encoding during three production
// deploys in a row. Deployed code imports npm: packages (pinned in _shared/deps.ts) and its own
// modules only; jsr: is for the tests, which are never bundled.
Deno.test("deployed function code imports nothing from jsr.io", () => {
  const offenders: string[] = [];
  const walk = (dir: URL, rel: string) => {
    for (const e of Deno.readDirSync(dir)) {
      if (e.isDirectory && e.name !== "_tests" && !e.name.startsWith(".")) {
        walk(new URL(`${e.name}/`, dir), `${rel}${e.name}/`);
      } else if (e.isFile && e.name.endsWith(".ts") && !e.name.endsWith("_test.ts")) {
        const src = Deno.readTextFileSync(new URL(e.name, dir));
        if (/from\s+["']jsr:|import\(\s*["']jsr:/.test(src)) offenders.push(`${rel}${e.name}`);
      }
    }
  };
  walk(functionsDir, "");
  assert(offenders.length === 0, `jsr: imports in deployed code: ${offenders.join(", ")}`);
});
