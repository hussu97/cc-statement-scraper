#!/usr/bin/env node
// Generates packages/db-types/src/database.ts from the local Supabase stack, normalised
// so the output is deterministic (audit X-34).
//
// `supabase gen types` orders each table's `Relationships` by foreign-key name, but
// entries that share a name (v_transactions joins `banks` twice through
// `accounts_bank_code_fkey`) come out in either order from one reset to the next.
// Every `Relationships` array is therefore stable-sorted by its entries' fields.
//
//   node packages/db-types/scripts/gen-types.mjs           write database.ts  (pnpm db:types)
//   node packages/db-types/scripts/gen-types.mjs --check   fail on drift      (pnpm db:types:check)
//
// A failed generator run never touches the committed file.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const TYPES_FILE = resolve(HERE, "../src/database.ts");
const GENERATE = ["supabase", ["gen", "types", "typescript", "--local"]];

// Sort keys, most significant first; the entry's full text breaks any remaining tie.
const KEY_FIELDS = ["foreignKeyName", "referencedRelation", "columns", "referencedColumns", "isOneToOne"];

function fieldsOf(lines) {
  const fields = {};
  for (const line of lines) {
    const m = /^\s*(\w+):\s*(.*?),?\s*$/.exec(line);
    if (m) fields[m[1]] = m[2];
  }
  return fields;
}

function compareEntries(a, b) {
  for (const k of KEY_FIELDS) {
    const x = a.fields[k] ?? "";
    const y = b.fields[k] ?? "";
    if (x !== y) return x < y ? -1 : 1;
  }
  return a.text < b.text ? -1 : a.text > b.text ? 1 : 0;
}

/**
 * Stable-sorts the entries of every multi-line `Relationships: [ … ]` array in a
 * `supabase gen types typescript` file. Everything else is returned byte for byte.
 * Throws if an array does not have the shape the generator emits, so a format change
 * fails loudly instead of being half-normalised.
 */
export function normalizeTypes(source) {
  const lines = source.split("\n");
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const open = /^(\s*)Relationships: \[$/.exec(lines[i]);
    out.push(lines[i]);
    if (!open) continue;

    const indent = open[1];
    const itemOpen = `${indent}  {`;
    const close = `${indent}]`;
    const entries = [];
    let j = i + 1;
    while (j < lines.length && lines[j] !== close) {
      if (lines[j] !== itemOpen) {
        throw new Error(`line ${j + 1}: expected "${itemOpen.trim()}" in Relationships, found "${lines[j].trim()}"`);
      }
      const start = j;
      while (j < lines.length && !/^\s*\},?$/.test(lines[j])) j++;
      if (j >= lines.length || !lines[j].startsWith(`${indent}  }`)) {
        throw new Error(`line ${start + 1}: unterminated Relationships entry`);
      }
      const body = lines.slice(start, j + 1);
      body[body.length - 1] = `${indent}  }`; // separators are re-added after sorting
      entries.push({ body, text: body.join("\n"), fields: fieldsOf(body.slice(1, -1)) });
      j++;
    }
    if (j >= lines.length) throw new Error(`line ${i + 1}: unterminated Relationships array`);

    entries.sort(compareEntries); // Array.prototype.sort is stable
    // The generator separates entries with "}," and leaves the last one bare.
    const last = lines[j - 1];
    entries.forEach((e, n) => {
      const body = [...e.body];
      if (n < entries.length - 1 || last.endsWith(",")) body[body.length - 1] += ",";
      out.push(...body);
    });
    out.push(lines[j]);
    i = j;
  }
  return out.join("\n");
}

function generate() {
  const [cmd, args] = GENERATE;
  const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.error) throw new Error(`could not run ${cmd}: ${r.error.message}`);
  if (r.status !== 0) {
    process.stderr.write(r.stderr ?? "");
    throw new Error(`${cmd} ${args.join(" ")} exited with ${r.status}`);
  }
  if (!r.stdout.includes("export type Database")) {
    throw new Error(`${cmd} ${args.join(" ")} printed no types (is the local stack running?)`);
  }
  return normalizeTypes(r.stdout);
}

function check(generated) {
  const committed = readFileSync(TYPES_FILE, "utf8");
  if (committed === generated) return true;
  const dir = mkdtempSync(join(tmpdir(), "db-types-"));
  try {
    const fresh = join(dir, "database.ts");
    writeFileSync(fresh, generated);
    spawnSync("diff", ["-u", TYPES_FILE, fresh], { stdio: "inherit" });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  return false;
}

function main(argv) {
  const generated = generate();
  if (argv.includes("--check")) {
    if (check(generated)) return 0;
    console.error("packages/db-types is stale. Run 'pnpm db:types' and commit the result.");
    return 1;
  }
  writeFileSync(TYPES_FILE, generated);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    console.error(`db-types: ${err.message}`);
    process.exitCode = 1;
  }
}
